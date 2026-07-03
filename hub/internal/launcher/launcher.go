// Package launcher lança tarefas nas máquinas-alvo e fecha o laço de controle
// bidirecional: aprovar/negar pedidos de permissão e enviar texto às sessões
// vivas (docs/02-arquitetura.md, Command API → Adapter).
//
// O Launcher decora o State Engine como um Applier: intercepta os eventos do
// Runner para guardar o pedido de permissão pendente (o request_id nativo e o
// input original da ferramenta), mas delega SEMPRE ao Engine — que segue o
// único escritor do Registry. Aprovar/negar exige que a sessão esteja mesmo em
// needs_you (rejeita ação obsoleta) e nunca aprova sem que o app tenha exibido
// o texto do pedido (invariante de segurança do docs/03).
package launcher

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Erros tipados, mapeados para os status HTTP pelos handlers REST.
var (
	ErrUnknownMachine  = errors.New("launcher: máquina desconhecida")
	ErrUnknownAgent    = errors.New("launcher: agente desconhecido")
	ErrLaunchTimeout   = errors.New("launcher: timeout esperando session_started")
	ErrUnknownSession  = errors.New("launcher: sessão desconhecida")
	ErrStaleState      = errors.New("launcher: estado obsoleto (não está em needs_you)")
	ErrNoHandle        = errors.New("launcher: sessão sem canal vivo")
	ErrTooManySessions = errors.New("launcher: limite de sessões concorrentes atingido (SEC-007)")
	ErrShuttingDown    = errors.New("launcher: hub está encerrando")
)

// agentClaudeCode é o único agente suportado nesta fase (dev).
const agentClaudeCode = "claude-code"

// denyMessage é a justificativa enviada ao agente ao negar uma permissão.
const denyMessage = "negado pela usuária via Cutuque"

// defaultMaxSessions é o teto de sessões concorrentes vivas quando ninguém
// chama SetMaxSessions (SEC-007). cmd/hub sobrescreve com CUTUQUE_MAX_SESSIONS.
const defaultMaxSessions = 20

// launchTimeout é quanto Launch espera pelo session_started antes de desistir.
// Var (não const) para os testes poderem encurtar.
var launchTimeout = 20 * time.Second

// pending é o pedido de permissão vivo de uma sessão: o request_id nativo (alvo
// do control_response) e o input original da ferramenta (devolvido intacto como
// updatedInput ao aprovar — protocolo verificado na CLI 2.1.198).
type pending struct {
	requestID string
	input     json.RawMessage
}

// Launcher lança e controla sessões do Claude Code nas máquinas registradas.
type Launcher struct {
	eng     *engine.Engine
	reg     *registry.Registry
	targets map[string]claudecode.Target

	// wg rastreia as goroutines de observação (uma por Launch, rodando
	// runner.Run) ainda vivas. Shutdown espera todas terminarem depois de
	// fechar os Handles — mesmo padrão do notifier (Close cancela e só
	// depois dá wg.Wait) para não vazar goroutine (review/patterns.md,
	// "recurso-de-longa-duração-sem-cancelamento").
	wg sync.WaitGroup

	// baseCtx é o contexto de vida das sessões (NÃO o ctx do request, que é
	// Background e nunca cancela). Shutdown cancela baseCancel para matar os
	// processos em voo — inclusive sessões cujo Handle ainda nem foi registrado
	// (review F5, achado bloqueante #2).
	baseCtx    context.Context
	baseCancel context.CancelFunc

	mu          sync.Mutex
	closed      bool                          // Shutdown em curso: Launch falha rápido
	handles     map[string]*claudecode.Handle // canal stdin/stdout por sessão viva
	pending     map[string]pending            // permissão aguardando resposta, por sessão
	maxSessions int                           // teto de sessões concorrentes vivas (SEC-007)
}

// New cria um Launcher sobre o Engine/Registry dados e o mapa de alvos
// (nome da máquina → Target). O Registry é consultado para validar o estado
// antes de aprovar/negar. O teto de sessões concorrentes começa em
// defaultMaxSessions; cmd/hub ajusta via SetMaxSessions com CUTUQUE_MAX_SESSIONS.
func New(eng *engine.Engine, reg *registry.Registry, targets map[string]claudecode.Target) *Launcher {
	ctx, cancel := context.WithCancel(context.Background())
	return &Launcher{
		eng:         eng,
		reg:         reg,
		targets:     targets,
		baseCtx:     ctx,
		baseCancel:  cancel,
		handles:     make(map[string]*claudecode.Handle),
		pending:     make(map[string]pending),
		maxSessions: defaultMaxSessions,
	}
}

// SetMaxSessions ajusta o teto de sessões concorrentes vivas (SEC-007).
// Valores não-positivos são ignorados (mantém o teto atual) — mesmo padrão de
// validação do Notifier.SetRenudgeInterval.
func (l *Launcher) SetMaxSessions(n int) {
	if n <= 0 {
		return
	}
	l.mu.Lock()
	l.maxSessions = n
	l.mu.Unlock()
}

// Launch inicia uma tarefa na máquina dada com o prompt dado, observando-a em
// uma goroutine. Valida machine/agent (dev: só máquinas registradas + claude-code),
// rejeita acima do teto de sessões concorrentes (SEC-007, ErrTooManySessions),
// envia o prompt inicial pelo stdin e espera o session_started (até launchTimeout)
// para devolver a Session criada.
func (l *Launcher) Launch(ctx context.Context, machine, agent, prompt string) (session.Session, error) {
	tgt, ok := l.targets[machine]
	if !ok {
		return session.Session{}, ErrUnknownMachine
	}
	if agent != agentClaudeCode {
		return session.Session{}, ErrUnknownAgent
	}

	// Porta fechada + teto + registro do em-voo, tudo sob o MESMO mutex:
	//   - closed: se o Shutdown começou, Launch falha rápido (não cria órfão).
	//   - teto de sessões (SEC-007): rejeita acima de maxSessions.
	//   - wg.Add ANTES do Start: a sessão em voo já conta no WaitGroup, então
	//     Shutdown sempre a espera, mesmo antes do Handle ser registrado no
	//     session_started (review F5, achado bloqueante #2).
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return session.Session{}, ErrShuttingDown
	}
	if len(l.handles) >= l.maxSessions {
		l.mu.Unlock()
		return session.Session{}, ErrTooManySessions
	}
	l.wg.Add(1)
	l.mu.Unlock()

	// A partir do wg.Add, TODA saída precisa liberar o wg (Done manual nos erros
	// abaixo; defer wg.Done na goroutine no caminho feliz). Usa l.baseCtx (não o
	// ctx do request, que é Background e nunca cancela) para que o Shutdown mate
	// o processo em voo cancelando baseCtx.
	handle, err := tgt.Start(l.baseCtx, "")
	if err != nil {
		l.wg.Done()
		return session.Session{}, err
	}
	// Prompt inicial pelo stdin (canal verificado): a fake/real lê a user message.
	if err := handle.SendUserMessage(prompt); err != nil {
		_ = handle.Close()
		l.wg.Done()
		return session.Session{}, err
	}

	started := make(chan session.Session, 1)
	app := &launchApplier{l: l, handle: handle, started: started}
	runner := claudecode.NewRunner(app)
	go func() {
		defer l.wg.Done()
		_ = runner.Run(l.baseCtx, handle, claudecode.Meta{Machine: machine, Prompt: prompt})
		// Fim do stream: a sessão não tem mais canal vivo.
		if app.sessionID != "" {
			l.removeHandle(app.sessionID)
		}
		_ = handle.Close()
	}()

	select {
	case s := <-started:
		return s, nil
	case <-time.After(launchTimeout):
		_ = handle.Close()
		return session.Session{}, ErrLaunchTimeout
	}
}

// Machines devolve os nomes dos alvos registrados, ordenados. targets é fixado
// em New e nunca mutado, então é seguro ler sem lock.
func (l *Launcher) Machines() []string {
	names := make([]string, 0, len(l.targets))
	for name := range l.targets {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Remove apaga uma sessão: fecha o Handle vivo (encerra o processo ssh/claude,
// se houver) e a remove do Registry junto do output. ErrUnknownSession se não
// havia nem handle vivo nem sessão no Registry.
func (l *Launcher) Remove(id string) error {
	l.mu.Lock()
	h, hadHandle := l.handles[id]
	delete(l.handles, id)
	delete(l.pending, id)
	l.mu.Unlock()

	if hadHandle {
		_ = h.Close() // mata o processo; a goroutine de Run termina no EOF
	}
	removed := l.reg.Remove(id)
	if !hadHandle && !removed {
		return ErrUnknownSession
	}
	return nil
}

// Approve aprova o pedido de permissão pendente da sessão (behavior=allow, com
// o input original como updatedInput).
func (l *Launcher) Approve(id string) error { return l.respond(id, true) }

// Deny nega o pedido de permissão pendente da sessão (behavior=deny + message).
func (l *Launcher) Deny(id string) error { return l.respond(id, false) }

// respond valida o estado (needs_you) e o pendente, escreve o control_response
// pelo stdin e aplica user_responded (→ running) ao Engine.
func (l *Launcher) respond(id string, allow bool) error {
	s, ok := l.reg.Get(id)
	if !ok {
		return ErrUnknownSession
	}
	if s.State != session.StateNeedsYou {
		return ErrStaleState // ação obsoleta: a sessão não está mais pedindo
	}

	// Reivindicação ATÔMICA do pendente: ler E remover na mesma seção crítica.
	// Sem isso, Approve/Deny concorrentes passam ambos pela validação e escrevem
	// dois control_response para o MESMO request_id (review F3, achado #2).
	l.mu.Lock()
	p, hasPending := l.pending[id]
	h, hasHandle := l.handles[id]
	if hasPending && hasHandle {
		delete(l.pending, id) // só o vencedor da corrida chega à escrita
	}
	l.mu.Unlock()
	if !hasPending || !hasHandle {
		return ErrStaleState // needs_you sem permissão viva (ex.: era só uma pergunta)
	}

	if err := h.WriteJSON(buildControlResponse(p, allow)); err != nil {
		// Falha de I/O: devolve o pendente para permitir nova tentativa.
		l.setPending(id, p)
		return err
	}
	l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
	return nil
}

// SendText continua a conversa da sessão. Se há um processo VIVO (turno em
// andamento / needs_you), manda o texto pro stdin dele. Se a sessão já ENCERROU
// (done/error/idle, sem processo), retoma a MESMA conversa com `claude --resume`
// — preservando o contexto (mesmo session_id, verificado na CLI 2.1.199). É o
// que dá continuidade: perguntar de novo responde na mesma sessão.
func (l *Launcher) SendText(id, text string) error {
	s, ok := l.reg.Get(id)
	if !ok {
		return ErrUnknownSession
	}
	l.mu.Lock()
	h, live := l.handles[id]
	l.mu.Unlock()

	if live {
		if err := h.SendUserMessage(text); err != nil {
			return err
		}
		l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
		return nil
	}
	// Sessão encerrada: retoma com --resume, roteando tudo para o MESMO id.
	return l.resume(s, text)
}

// resume retoma uma conversa encerrada rodando `claude --resume <id>` na mesma
// máquina, roteando TODO o stream para o mesmo session id (forcedID). Espelha o
// Launch, mas não espera um novo session_started nem checa teto (é continuação).
func (l *Launcher) resume(s session.Session, prompt string) error {
	tgt, ok := l.targets[s.Machine]
	if !ok {
		return ErrUnknownMachine
	}

	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return ErrShuttingDown
	}
	l.wg.Add(1)
	l.mu.Unlock()

	handle, err := tgt.Start(l.baseCtx, s.ID) // --resume s.ID
	if err != nil {
		l.wg.Done()
		return err
	}
	if err := handle.SendUserMessage(prompt); err != nil {
		_ = handle.Close()
		l.wg.Done()
		return err
	}
	// Registra o handle já para o id conhecido: aprovar/negar do turno retomado
	// funciona mesmo antes do session_started chegar.
	l.setHandle(s.ID, handle)

	app := &launchApplier{l: l, handle: handle, forcedID: s.ID}
	runner := claudecode.NewRunner(app)
	go func() {
		defer l.wg.Done()
		_ = runner.Run(l.baseCtx, handle, claudecode.Meta{Machine: s.Machine, Prompt: prompt})
		l.removeHandle(s.ID)
		_ = handle.Close()
	}()
	return nil
}

func (l *Launcher) setPending(id string, p pending) {
	l.mu.Lock()
	l.pending[id] = p
	l.mu.Unlock()
}

func (l *Launcher) clearPending(id string) {
	l.mu.Lock()
	delete(l.pending, id)
	l.mu.Unlock()
}

func (l *Launcher) setHandle(id string, h *claudecode.Handle) {
	l.mu.Lock()
	l.handles[id] = h
	l.mu.Unlock()
}

func (l *Launcher) removeHandle(id string) {
	l.mu.Lock()
	delete(l.handles, id)
	l.mu.Unlock()
}

// Shutdown encerra TODAS as sessões vivas: fecha cada Handle (sinaliza EOF ao
// agente e espera o processo terminar, via Handle.Close) e limpa os mapas
// internos. Chamado no graceful shutdown do processo (cmd/hub/main.go), DEPOIS
// de srv.Shutdown ter parado de aceitar requests novos — se um Launch ainda
// estivesse em voo, seu Handle não estaria em l.handles ainda (só entra no
// session_started) e não seria fechado aqui; a ordem do main.go evita essa
// janela.
//
// Fecha os Handles FORA do lock: Close() pode bloquear esperando o processo
// terminar, e a goroutine de observação de cada Launch (Run) também precisa do
// mesmo mutex para chamar removeHandle no fim natural do stream — segurar o
// lock durante o Close causaria deadlock. Só depois de soltar o lock e fechar
// tudo é que esperamos wg.Wait(): mesmo padrão do Notifier.Close (cancela
// primeiro, espera depois) para não vazar goroutine
// (review/patterns.md#recurso-de-longa-duração-sem-cancelamento).
func (l *Launcher) Shutdown() {
	l.mu.Lock()
	l.closed = true // fecha a porta na MESMA seção do snapshot: Launch novo falha rápido
	handles := make([]*claudecode.Handle, 0, len(l.handles))
	for _, h := range l.handles {
		handles = append(handles, h)
	}
	l.handles = make(map[string]*claudecode.Handle)
	l.pending = make(map[string]pending)
	l.mu.Unlock()

	// Cancela o contexto-base: mata os processos em voo, inclusive sessões cujo
	// Handle ainda não foi registrado (Start em andamento) — sem isso, wg.Wait
	// abaixo travaria esperando uma goroutine cujo processo ninguém fechou.
	l.baseCancel()
	for _, h := range handles {
		_ = h.Close()
	}
	l.wg.Wait()
}

// launchApplier decora o Engine para uma sessão em observação: guarda/limpa o
// pendente conforme os eventos e delega SEMPRE ao Engine (único escritor).
type launchApplier struct {
	l         *Launcher
	handle    *claudecode.Handle
	started   chan session.Session
	sessionID string // preenchido no session_started (usado na limpeza ao fim)
	forcedID  string // resume: força todos os eventos para este id (continuidade)
}

func (a *launchApplier) Apply(ev event.Event) {
	// Resume: garante que TODO evento vá para a sessão que estamos continuando,
	// independente do que o claude reporte no init (defesa; o id é o mesmo).
	if a.forcedID != "" {
		ev.SessionID = a.forcedID
	}
	switch ev.Type {
	case event.PermissionRequested:
		a.l.setPending(ev.SessionID, pending{requestID: ev.ControlID, input: ev.Input})
	case event.NeedsInput, event.UserResponded, event.Finished, event.Errored:
		// Qualquer outro evento de estado: não há permissão viva a responder.
		a.l.clearPending(ev.SessionID)
	}

	a.l.eng.Apply(ev) // delega SEMPRE ao Engine

	if ev.Type == event.SessionStarted {
		a.sessionID = ev.SessionID
		a.l.setHandle(ev.SessionID, a.handle)
		if s, ok := a.l.reg.Get(ev.SessionID); ok {
			select {
			case a.started <- s:
			default:
			}
		}
	}
}

// controlResponse é a resposta ao control_request nativo (shape verificado na
// CLI 2.1.198). O wrapper tem subtype "success" (o protocolo de controle deu
// certo); o response interno carrega a decisão (allow/deny).
type controlResponse struct {
	Type     string              `json:"type"`
	Response controlResponseBody `json:"response"`
}

type controlResponseBody struct {
	Subtype   string   `json:"subtype"`
	RequestID string   `json:"request_id"`
	Response  decision `json:"response"`
}

type decision struct {
	Behavior     string          `json:"behavior"`
	UpdatedInput json.RawMessage `json:"updatedInput,omitempty"` // allow: input original intacto
	Message      string          `json:"message,omitempty"`      // deny: justificativa
}

// buildControlResponse monta o control_response de allow (devolvendo o input
// original como updatedInput) ou deny (com a mensagem padrão).
func buildControlResponse(p pending, allow bool) controlResponse {
	d := decision{}
	if allow {
		d.Behavior = "allow"
		input := p.input
		if len(input) == 0 {
			input = json.RawMessage(`{}`)
		}
		d.UpdatedInput = input
	} else {
		d.Behavior = "deny"
		d.Message = denyMessage
	}
	return controlResponse{
		Type: "control_response",
		Response: controlResponseBody{
			Subtype:   "success",
			RequestID: p.requestID,
			Response:  d,
		},
	}
}
