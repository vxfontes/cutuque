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
	"sync/atomic"
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

// defaultRenudge é o intervalo do re-cutucão quando nada é configurado.
const defaultRenudge = 15 * time.Second

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

	renudgeNanos atomic.Int64 // intervalo do re-cutucão (ns); ajustável em runtime

	// Estado de foreground do app (suprime push enquanto aberto). fgUntil é o
	// unix-nano até quando suprimir; fgLastAt é o maior timestamp monotônico do
	// cliente já aceito — updates que chegam FORA DE ORDEM (ex.: um heartbeat
	// `true` em voo chegando depois do `false` de background) são descartados,
	// para não reabrir a supressão com o app já em background (SEC-102). Um
	// mutex dedicado garante check+store atômico do par.
	fgMu     sync.Mutex
	fgUntil  int64
	fgLastAt int64
	muted    bool // "app desligado": para TODO push (needs_you/done/live activity)

	mu     sync.Mutex
	closed bool                          // Close() em curso: não spawna novos nudges
	states map[string]session.State      // último estado notificado por sessão
	nudges map[string]context.CancelFunc // re-cutucão ativo por sessão em needs_you
	// donePushes: push de "concluído" AGENDADO (adiado) por sessão externa —
	// cancelado se a sessão voltar a rodar antes do prazo, para coalescer os
	// vários Stop de uma conversa interativa em um único push (review #1).
	donePushes map[string]context.CancelFunc
	doneDelay  time.Duration // prazo do push adiado; injetável nos testes

	// Última contagem agregada empurrada pra Live Activity (evita push repetido).
	// -1 = ainda não empurrou.
	laLive   int
	laActive int
}

// doneCoalesceDelay é quanto o push de "concluído" de uma sessão externa espera
// antes de disparar. Se a sessão receber um novo turno (→ running) nesse intervalo,
// o push é cancelado. Perto do timeout de ociosidade do próprio Claude (~60s) para
// não cutucar enquanto a usuária ainda está lendo/pensando entre turnos.
const doneCoalesceDelay = 45 * time.Second

// SetRenudgeInterval ajusta o intervalo do re-cutucão em runtime (aplicado no
// próximo ciclo de cada sessão). Só rejeita valores não-positivos; a validação
// de faixa (min/max) é responsabilidade de quem expõe isso (o handler /settings).
func (n *Notifier) SetRenudgeInterval(d time.Duration) {
	if d <= 0 {
		return
	}
	n.renudgeNanos.Store(int64(d))
}

// RenudgeInterval devolve o intervalo atual do re-cutucão.
func (n *Notifier) RenudgeInterval() time.Duration {
	d := time.Duration(n.renudgeNanos.Load())
	if d <= 0 {
		return defaultRenudge
	}
	return d
}

// foregroundTTL é por quanto tempo um "estou em foreground" vale sem renovação.
// O app manda heartbeat mais frequente que isso; o TTL só protege contra o app
// morrer sem mandar "background" (senão o push ficaria suprimido para sempre).
const foregroundTTL = 150 * time.Second

// SetForeground marca se o app está aberto/em foreground. `at` é um timestamp
// monotônico do cliente (ms): updates com `at` menor que o último aceito são
// ignorados (chegaram fora de ordem) — assim um `true` atrasado nunca reabre a
// supressão depois de um `false` mais recente (SEC-102). Enquanto ativo e dentro
// do TTL, fanout suprime o push (o app já recebe tudo pelo WS).
func (n *Notifier) SetForeground(active bool, at int64) {
	n.fgMu.Lock()
	defer n.fgMu.Unlock()
	if at < n.fgLastAt {
		return // update fora de ordem: descarta
	}
	n.fgLastAt = at
	if active {
		n.fgUntil = time.Now().Add(foregroundTTL).UnixNano()
	} else {
		n.fgUntil = 0
	}
}

// foregroundSuppressed diz se o push deve ser suprimido agora — app em foreground
// (dentro do TTL) OU "desligado" (muted). Nos dois casos o hub não cutuca.
func (n *Notifier) foregroundSuppressed() bool {
	n.fgMu.Lock()
	defer n.fgMu.Unlock()
	if n.muted {
		return true
	}
	return n.fgUntil > 0 && time.Now().UnixNano() < n.fgUntil
}

// SetMuted liga/desliga o modo "app desligado": mudo = nenhum push (needs_you,
// done, Live Activity) até religar.
func (n *Notifier) SetMuted(muted bool) {
	n.fgMu.Lock()
	n.muted = muted
	n.fgMu.Unlock()
}

// New cria um Notifier. Se logger for nil, descarta logs (não é fatal).
func New(pusher Pusher, store *devices.Store, reg *registry.Registry, logger *slog.Logger) *Notifier {
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	n := &Notifier{
		apns:       pusher,
		devices:    store,
		reg:        reg,
		logger:     logger,
		states:     make(map[string]session.State),
		nudges:     make(map[string]context.CancelFunc),
		donePushes: make(map[string]context.CancelFunc),
		doneDelay:  doneCoalesceDelay,
		laLive:     -1,
		laActive:   -1,
	}
	n.renudgeNanos.Store(int64(defaultRenudge))
	return n
}

// Start assina o Registry e passa a processar as mudanças em background. Chame
// Close para encerrar (o graceful shutdown do processo continua como dívida —
// ver review/log.md; aqui só garantimos o fim limpo da goroutine).
func (n *Notifier) Start() {
	n.sub = n.reg.Subscribe()
	n.wg.Add(1)
	go n.loop()
}

// Close encerra a inscrição (fecha o canal → o loop termina), cancela todos os
// re-cutucões ativos e espera as goroutines pendentes. Idempotente o suficiente
// para os testes.
func (n *Notifier) Close() {
	if n.sub != nil {
		n.reg.Unsubscribe(n.sub)
	}
	n.mu.Lock()
	n.closed = true // fecha a porta para novos nudges na MESMA seção do cancelamento
	for id, cancel := range n.nudges {
		cancel()
		delete(n.nudges, id)
	}
	for id, cancel := range n.donePushes {
		cancel()
		delete(n.donePushes, id)
	}
	n.mu.Unlock()
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
	// Qualquer mudança no registry pode mexer no agregado da Live Activity —
	// recomputa e (se o app estiver fechado) empurra a atualização.
	n.maybePushLiveActivity()

	n.mu.Lock()
	prev, seen := n.states[s.ID]
	n.mu.Unlock()

	if seen && prev == s.State {
		return // estado inalterado (ex.: rebroadcast de pending prompt)
	}

	// Subagente / sessão externa SEM pane de tmux: não é acionável pelo app (sem
	// terminal ao vivo) e fica "arquivada" na aba Subagentes — NÃO cutuca, senão
	// os subagentes do maestri inundariam a usuária com push sem sentido. Só
	// registra o estado (e encerra qualquer nudge/done pendente).
	if s.External && s.Pane == "" {
		n.stopNudge(s.ID)
		n.cancelDonePush(s.ID)
		n.setState(s.ID, s.State)
		return
	}

	switch s.State {
	case session.StateNeedsYou:
		if s.PendingPrompt == "" {
			// Aguarda o broadcast com o texto do pedido; NÃO marca como visto
			// ainda, para o próximo (com texto) contar como a transição.
			return
		}
		// Novo pedido cancela um push de "concluído" adiado (a sessão não estava
		// realmente ociosa).
		n.cancelDonePush(s.ID)
	case session.StateDone, session.StateError:
		// Saiu de needs_you (ou nunca esteve): encerra qualquer re-cutucão.
		n.stopNudge(s.ID)
		if s.External {
			// Sessão externa (hook/tmux): a usuária quer ser avisada quando a
			// sessão CONCLUI. Mas o Stop do Claude dispara a cada turno, então
			// cutucar na hora viraria um push por turno numa conversa interativa
			// (review #1). Em vez disso, AGENDA o push e o cancela se a sessão
			// voltar a rodar (novo prompt) antes do prazo — resultado: UM push
			// quando a usuária de fato parou, não a cada resposta.
			n.setState(s.ID, s.State)
			n.scheduleDonePush(s.ID)
			return
		}
		// Sessão lançada pelo hub: push imediato (segue abaixo).
	default:
		// running/idle: sem push. Encerra re-cutucão (ex.: aprovou → running),
		// cancela push de done adiado (novo turno começou) e registra o estado.
		n.stopNudge(s.ID)
		n.cancelDonePush(s.ID)
		n.setState(s.ID, s.State)
		return
	}

	n.setState(s.ID, s.State)
	payload, opts := buildPush(s)
	n.fanout(payload, opts)

	// needs_you: além do push imediato, re-cutuca a cada renudgeInterval até a
	// sessão sair de needs_you. SÓ para sessões lançadas pelo hub (que a usuária
	// resolve no app). Sessões externas (hook/tmux) são resolvidas no terminal —
	// o hub não sabe quando isso aconteceu, então re-cutucar seria infinito: elas
	// avisam uma vez só (review: "push sem parar").
	if s.State == session.StateNeedsYou && !s.External {
		n.startNudge(s.ID)
	}
}

// startNudge inicia (ou reinicia) o re-cutucão periódico de uma sessão em
// needs_you. Substitui um re-cutucão anterior da mesma sessão, se houver.
func (n *Notifier) startNudge(id string) {
	ctx, cancel := context.WithCancel(context.Background())
	n.mu.Lock()
	if n.closed {
		// Close() já cancelou tudo: não spawna nova goroutine (senão ela ficaria
		// órfã segurando o WaitGroup e travaria o Close — review F4.1, ludmilla).
		n.mu.Unlock()
		cancel()
		return
	}
	if old, ok := n.nudges[id]; ok {
		old() // cancela o anterior antes de substituir
	}
	n.nudges[id] = cancel
	n.mu.Unlock()

	n.wg.Add(1)
	go n.nudgeLoop(ctx, id)
}

// stopNudge cancela e remove o re-cutucão de uma sessão, se ativo.
func (n *Notifier) stopNudge(id string) {
	n.mu.Lock()
	if cancel, ok := n.nudges[id]; ok {
		cancel()
		delete(n.nudges, id)
	}
	n.mu.Unlock()
}

// scheduleDonePush agenda (ou reagenda) o push de "concluído" de uma sessão
// externa para daqui a doneCoalesceDelay. Se a sessão sair de done/error antes
// disso (novo turno → running), cancelDonePush o cancela — assim uma conversa
// interativa no tmux gera UM push (quando a usuária de fato para), não um por
// turno (review #1).
func (n *Notifier) scheduleDonePush(id string) {
	ctx, cancel := context.WithCancel(context.Background())
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		cancel()
		return
	}
	if old, ok := n.donePushes[id]; ok {
		old() // cancela o agendamento anterior antes de substituir
	}
	n.donePushes[id] = cancel
	n.mu.Unlock()

	n.wg.Add(1)
	go n.donePushLoop(ctx, id)
}

// cancelDonePush cancela e remove o push de done agendado de uma sessão, se houver.
func (n *Notifier) cancelDonePush(id string) {
	n.mu.Lock()
	if cancel, ok := n.donePushes[id]; ok {
		cancel()
		delete(n.donePushes, id)
	}
	n.mu.Unlock()
}

// donePushLoop espera doneCoalesceDelay e, se a sessão AINDA estiver done/error
// (a usuária não retomou), dispara o push uma única vez. Encerra ao ser cancelado.
func (n *Notifier) donePushLoop(ctx context.Context, id string) {
	defer n.wg.Done()
	select {
	case <-ctx.Done():
		return
	case <-time.After(n.doneDelay):
		s, ok := n.reg.Get(id)
		if !ok || (s.State != session.StateDone && s.State != session.StateError) {
			return // retomou ou sumiu: não cutuca
		}
		n.mu.Lock()
		delete(n.donePushes, id) // este timer cumpriu seu papel
		n.mu.Unlock()
		payload, opts := buildPush(s)
		n.fanout(payload, opts)
	}
}

// nudgeLoop re-envia o push de needs_you a cada renudgeInterval enquanto a
// sessão continuar em needs_you (o Registry é a fonte da verdade a cada tick).
// Encerra ao ser cancelado (transição de estado ou Close).
func (n *Notifier) nudgeLoop(ctx context.Context, id string) {
	defer n.wg.Done()
	for {
		// time.After a cada volta: relê o intervalo, então mudanças em runtime
		// (via /settings) valem já no próximo ciclo.
		select {
		case <-ctx.Done():
			return
		case <-time.After(n.RenudgeInterval()):
			s, ok := n.reg.Get(id)
			if !ok || s.State != session.StateNeedsYou {
				return // já resolveu: para de cutucar
			}
			payload, opts := buildPush(s)
			n.fanout(payload, opts)
		}
	}
}

// setState registra o último estado notificado de uma sessão.
func (n *Notifier) setState(id string, st session.State) {
	n.mu.Lock()
	n.states[id] = st
	n.mu.Unlock()
}

// maybePushLiveActivity recomputa o agregado (sessões ao vivo / rodando) e, se
// mudou E o app NÃO estiver em foreground (aí é o app quem dirige a activity
// localmente), empurra uma atualização de Live Activity para os tokens de
// activity registrados. Assim a ilha/tela de bloqueio atualiza com o app fechado.
func (n *Notifier) maybePushLiveActivity() {
	live, active := n.aggregateCounts()
	n.mu.Lock()
	changed := live != n.laLive || active != n.laActive
	n.laLive, n.laActive = live, active
	n.mu.Unlock()
	if !changed || n.foregroundSuppressed() {
		return
	}
	payload := buildLiveActivityPayload(live, active, live == 0)
	for _, d := range n.devices.List() {
		if d.Platform != "liveactivity" {
			continue
		}
		n.wg.Add(1)
		go func(token string) {
			defer n.wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), pushTimeout)
			defer cancel()
			err := n.apns.Push(ctx, token, payload, apns.PushOptions{PushType: "liveactivity", Priority: 10})
			if errors.Is(err, apns.ErrGone) {
				n.devices.Remove(token) // activity encerrada/expirada
			} else if err != nil {
				n.logger.Warn("falha no push de live activity", "err", err, "token_prefix", tokenPrefix(token))
			}
		}(d.Token)
	}
}

// aggregateCounts conta as sessões de tmux (external com pane) ao vivo e quantas
// rodando — a partir do registry (o que o hub conhece), consistente com o app.
func (n *Notifier) aggregateCounts() (live, active int) {
	for _, s := range n.reg.List() {
		if s.External && s.Pane != "" {
			live++
			if s.State == session.StateRunning {
				active++
			}
		}
	}
	return
}

// buildLiveActivityPayload monta o payload APNs de atualização (ou fim) da Live
// Activity com o content-state {live, active}.
func buildLiveActivityPayload(live, active int, end bool) []byte {
	now := time.Now()
	aps := map[string]any{
		"timestamp":       now.Unix(),
		"content-state":   map[string]int{"live": live, "active": active},
		"relevance-score": 100,
	}
	if end {
		aps["event"] = "end"
		aps["dismissal-date"] = now.Unix()
	} else {
		aps["event"] = "update"
		aps["stale-date"] = now.Add(2 * time.Hour).Unix()
	}
	b, _ := json.Marshal(map[string]any{"aps": aps})
	return b
}

// fanout envia o push a todos os devices, um por goroutine com timeout próprio.
// Um 410 remove o device; outros erros só são logados.
func (n *Notifier) fanout(payload []byte, opts apns.PushOptions) {
	// App em foreground: não dispara push (a usuária já vê tudo ao vivo pelo WS).
	if n.foregroundSuppressed() {
		n.logger.Info("push suprimido: app em foreground")
		return
	}
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
