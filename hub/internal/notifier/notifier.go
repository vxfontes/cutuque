// Package notifier liga o State Engine à APNs: assina as mudanças do Registry,
// detecta as TRANSIÇÕES relevantes (→ needs_you, → done, → error) e envia um
// push com METADADOS APENAS — zero código-fonte ou output da sessão (invariante
// de segurança do docs/02 e review/security.md). Faz fan-out para todos os
// devices registrados; um 410 Unregistered remove o device.
package notifier

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/apns"
	"github.com/vxfontes/cutuque/hub/internal/devices"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// pushTimeout é o teto por device no fan-out: um device lento/inalcançável não
// pode segurar os demais nem vazar goroutine para sempre.
const pushTimeout = 10 * time.Second

// promptMaxLen é o tamanho máximo (em runes) do resumo do pedido no body do push
// de needs_you. É o resumo do permission_requested — necessário para o
// invariante de nunca aprovar às cegas pelo pulso —, NÃO output/código.
const promptMaxLen = 140

// Pusher é a superfície da APNs que o Notifier consome. *apns.Client a satisfaz;
// um fake a implementa nos testes.
type Pusher interface {
	Push(ctx context.Context, deviceToken string, payload []byte, opts apns.PushOptions) error
}

// Notifier observa o Registry e dispara push nas transições relevantes.
type Notifier struct {
	apns    Pusher
	devices *devices.Store
	reg     *registry.Registry
	logger  *slog.Logger

	sub *registry.Subscription
	wg  sync.WaitGroup

	mu     sync.Mutex
	states map[string]session.State // último estado notificado por sessão
}

// New cria um Notifier. Se logger for nil, descarta logs (não é fatal).
func New(pusher Pusher, store *devices.Store, reg *registry.Registry, logger *slog.Logger) *Notifier {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Notifier{
		apns:    pusher,
		devices: store,
		reg:     reg,
		logger:  logger,
		states:  make(map[string]session.State),
	}
}

// Start assina o Registry e passa a processar as mudanças em background. Chame
// Close para encerrar (o graceful shutdown do processo continua como dívida —
// ver review/log.md; aqui só garantimos o fim limpo da goroutine).
func (n *Notifier) Start() {
	n.sub = n.reg.Subscribe()
	n.wg.Add(1)
	go n.loop()
}

// Close encerra a inscrição (fecha o canal → o loop termina) e espera as
// goroutines de fan-out pendentes. Idempotente o suficiente para os testes.
func (n *Notifier) Close() {
	if n.sub != nil {
		n.reg.Unsubscribe(n.sub)
	}
	n.wg.Wait()
}

// loop consome as mudanças do Registry até o canal fechar (Unsubscribe).
func (n *Notifier) loop() {
	defer n.wg.Done()
	for s := range n.sub.C {
		n.handle(s)
	}
}

// handle decide se a mudança recebida é uma transição que merece push.
//
// Sutileza de contrato com o Engine: a transição → needs_you chega em DOIS
// broadcasts (UpdateState e depois SetPendingPrompt); o primeiro vem sem o texto
// do pedido. Só disparamos o push de needs_you quando o PendingPrompt já está
// presente, sem marcar a sessão como notificada antes disso — assim o segundo
// broadcast (com texto) é que conta como a transição. done/error disparam
// direto na transição.
func (n *Notifier) handle(s session.Session) {
	n.mu.Lock()
	prev, seen := n.states[s.ID]
	n.mu.Unlock()

	if seen && prev == s.State {
		return // estado inalterado (ex.: rebroadcast de pending prompt)
	}

	switch s.State {
	case session.StateNeedsYou:
		if s.PendingPrompt == "" {
			// Aguarda o broadcast com o texto do pedido; NÃO marca como visto
			// ainda, para o próximo (com texto) contar como a transição.
			return
		}
	case session.StateDone, session.StateError:
		// dispara na transição
	default:
		// running/idle: sem push, mas registra o estado para detectar as
		// próximas transições corretamente.
		n.setState(s.ID, s.State)
		return
	}

	n.setState(s.ID, s.State)
	payload, opts := buildPush(s)
	n.fanout(payload, opts)
}

// setState registra o último estado notificado de uma sessão.
func (n *Notifier) setState(id string, st session.State) {
	n.mu.Lock()
	n.states[id] = st
	n.mu.Unlock()
}

// fanout envia o push a todos os devices, um por goroutine com timeout próprio.
// Um 410 remove o device; outros erros só são logados.
func (n *Notifier) fanout(payload []byte, opts apns.PushOptions) {
	for _, d := range n.devices.List() {
		n.wg.Add(1)
		go func(token string) {
			defer n.wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
			defer cancel()

			err := n.apns.Push(ctx, token, payload, opts)
			switch {
			case errors.Is(err, apns.ErrGone):
				n.devices.Remove(token)
				n.logger.Info("device removido (410 Unregistered)", "token_prefix", tokenPrefix(token))
			case err != nil:
				n.logger.Warn("falha ao enviar push", "err", err, "token_prefix", tokenPrefix(token))
			}
		}(d.Token)
	}
}

// tokenPrefix devolve um prefixo curto do token para log (nunca o token inteiro).
func tokenPrefix(token string) string {
	if len(token) <= 8 {
		return token
	}
	return token[:8]
}

// pushPayload é o corpo do push. Só metadados: nada de output/código da sessão.
type pushPayload struct {
	APS       apsDict `json:"aps"`
	SessionID string  `json:"session_id"`
	Machine   string  `json:"machine"`
	Agent     string  `json:"agent"`
	State     string  `json:"state"`
}

// apsDict é o dicionário aps do APNs.
type apsDict struct {
	Alert             apsAlert `json:"alert"`
	Sound             string   `json:"sound"`
	ThreadID          string   `json:"thread-id"`
	Category          string   `json:"category"`
	InterruptionLevel string   `json:"interruption-level,omitempty"`
}

type apsAlert struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// buildPush monta o payload e as opções de header a partir da sessão. Só é
// chamado para needs_you/done/error (handle já filtrou os demais estados).
func buildPush(s session.Session) ([]byte, apns.PushOptions) {
	var alert apsAlert
	var category, interruption string

	switch s.State {
	case session.StateNeedsYou:
		alert = apsAlert{Title: "⚠️ " + s.Title, Body: truncateRunes(s.PendingPrompt, promptMaxLen)}
		category = "NEEDS_YOU"
		interruption = "time-sensitive"
	case session.StateDone:
		alert = apsAlert{Title: "✅ " + s.Title, Body: "concluiu · " + s.Machine}
		category = "DONE"
	case session.StateError:
		alert = apsAlert{Title: "❌ " + s.Title, Body: "falhou · " + s.Machine}
		category = "ERROR"
	}

	payload := pushPayload{
		APS: apsDict{
			Alert:             alert,
			Sound:             "default",
			ThreadID:          s.ID, // agrupa as notificações da mesma sessão
			Category:          category,
			InterruptionLevel: interruption,
		},
		SessionID: s.ID,
		Machine:   s.Machine,
		Agent:     s.Agent,
		State:     string(s.State),
	}
	// json.Marshal de structs simples só falha por tipos não-serializáveis, que
	// não existem aqui; o erro é impossível na prática.
	b, _ := json.Marshal(payload)

	// Não setamos ThreadID (apns-collapse-id): cada transição deve gerar uma
	// notificação distinta; o agrupamento visual vem de aps.thread-id.
	opts := apns.PushOptions{Category: category, PushType: "alert", Priority: 10}
	return b, opts
}

// truncateRunes corta a string em no máximo max runes (sem quebrar um rune).
func truncateRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}
