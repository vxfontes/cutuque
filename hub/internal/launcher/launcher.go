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
	ErrUnknownMachine = errors.New("launcher: máquina desconhecida")
	ErrUnknownAgent   = errors.New("launcher: agente desconhecido")
	ErrLaunchTimeout  = errors.New("launcher: timeout esperando session_started")
	ErrUnknownSession = errors.New("launcher: sessão desconhecida")
	ErrStaleState     = errors.New("launcher: estado obsoleto (não está em needs_you)")
	ErrNoHandle       = errors.New("launcher: sessão sem canal vivo")
)

// agentClaudeCode é o único agente suportado nesta fase (dev).
const agentClaudeCode = "claude-code"

// denyMessage é a justificativa enviada ao agente ao negar uma permissão.
const denyMessage = "negado pela usuária via Cutuque"

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

	mu      sync.Mutex
	handles map[string]*claudecode.Handle // canal stdin/stdout por sessão viva
	pending map[string]pending            // permissão aguardando resposta, por sessão
}

// New cria um Launcher sobre o Engine/Registry dados e o mapa de alvos
// (nome da máquina → Target). O Registry é consultado para validar o estado
// antes de aprovar/negar.
func New(eng *engine.Engine, reg *registry.Registry, targets map[string]claudecode.Target) *Launcher {
	return &Launcher{
		eng:     eng,
		reg:     reg,
		targets: targets,
		handles: make(map[string]*claudecode.Handle),
		pending: make(map[string]pending),
	}
}

// Launch inicia uma tarefa na máquina dada com o prompt dado, observando-a em
// uma goroutine. Valida machine/agent (dev: só máquinas registradas + claude-code),
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

	handle, err := tgt.Start(ctx)
	if err != nil {
		return session.Session{}, err
	}
	// Prompt inicial pelo stdin (canal verificado): a fake/real lê a user message.
	if err := handle.SendUserMessage(prompt); err != nil {
		_ = handle.Close()
		return session.Session{}, err
	}

	started := make(chan session.Session, 1)
	app := &launchApplier{l: l, handle: handle, started: started}
	runner := claudecode.NewRunner(app)
	go func() {
		_ = runner.Run(ctx, handle, claudecode.Meta{Machine: machine, Prompt: prompt})
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

	l.mu.Lock()
	p, hasPending := l.pending[id]
	h, hasHandle := l.handles[id]
	l.mu.Unlock()
	if !hasPending || !hasHandle {
		return ErrStaleState // needs_you sem permissão viva (ex.: era só uma pergunta)
	}

	if err := h.WriteJSON(buildControlResponse(p, allow)); err != nil {
		return err
	}
	l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
	l.clearPending(id)
	return nil
}

// SendText envia um input textual arbitrário à sessão viva e aplica
// user_responded (→ running). Exige um canal vivo (ErrNoHandle caso contrário).
func (l *Launcher) SendText(id, text string) error {
	if _, ok := l.reg.Get(id); !ok {
		return ErrUnknownSession
	}
	l.mu.Lock()
	h, ok := l.handles[id]
	l.mu.Unlock()
	if !ok {
		return ErrNoHandle
	}
	if err := h.SendUserMessage(text); err != nil {
		return err
	}
	l.eng.Apply(event.Event{SessionID: id, Type: event.UserResponded, At: time.Now()})
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

// launchApplier decora o Engine para uma sessão em observação: guarda/limpa o
// pendente conforme os eventos e delega SEMPRE ao Engine (único escritor).
type launchApplier struct {
	l         *Launcher
	handle    *claudecode.Handle
	started   chan session.Session
	sessionID string // preenchido no session_started (usado na limpeza ao fim)
}

func (a *launchApplier) Apply(ev event.Event) {
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
