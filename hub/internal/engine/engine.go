// Package engine é o State Engine: consome eventos normalizados e move cada
// sessão pela máquina de estados (docs/03-modelo-de-estado.md), atualizando o
// Registry. É a única peça que escreve o estado das sessões.
package engine

import (
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Engine aplica eventos ao Registry.
type Engine struct {
	reg *registry.Registry
}

// New cria um State Engine sobre o Registry dado.
func New(reg *registry.Registry) *Engine {
	return &Engine{reg: reg}
}

// Apply processa um evento normalizado, ajustando o estado da sessão.
//
//   - session_started: cria a sessão (running) se não existir, ou a devolve a
//     running (novo disparo sobre idle/done/error).
//   - output_chunk: mantém o estado (a sessão segue running); o armazenamento
//     do output é feito à parte (ver registry.AppendOutput).
//   - needs_input / permission_requested: → needs_you (e guarda o PendingPrompt).
//   - user_responded: → running (a usuária aprovou/respondeu).
//   - finished: → done.
//   - errored: → error.
//
// Regra de desempate (doc 03): na dúvida, prefira needs_you a assumir done —
// por isso needs_input/permission_requested levam a needs_you a partir de
// qualquer estado, inclusive done. Eventos para sessões desconhecidas (exceto
// session_started) e transições redundantes são ignorados sem erro.
func (e *Engine) Apply(ev event.Event) {
	switch ev.Type {
	case event.SessionStarted:
		e.ensureRunning(ev)
		return
	case event.OutputChunk:
		// Mantém o estado (a sessão segue running); só guarda o output para o
		// stream ao vivo. Ignora output de sessão desconhecida.
		if _, ok := e.reg.Get(ev.SessionID); ok {
			e.reg.AppendOutput(ev.SessionID, ev.Kind, ev.Data)
		}
		return
	}

	target, ok := targetState(ev.Type)
	if !ok {
		return // tipo sem efeito de estado
	}
	cur, exists := e.reg.Get(ev.SessionID)
	if !exists {
		return // sessão desconhecida: ignora
	}
	// user_responded só faz sentido saindo de needs_you (a usuária respondeu ao
	// pedido). De qualquer outro estado é no-op: evita regredir done→running numa
	// corrida entre a resposta (goroutine HTTP) e o evento terminal do stream
	// (goroutine do Runner) — ambos chamam Apply.
	if ev.Type == event.UserResponded && cur.State != session.StateNeedsYou {
		return
	}
	if cur.State == target {
		return // redundante: no-op (não mexe em UpdatedAt nem faz broadcast)
	}
	_ = e.reg.UpdateState(ev.SessionID, target)

	// PendingPrompt (o texto que o app exibe): entra em needs_you com o resumo
	// do pedido; some ao sair de needs_you (aprovou/terminou/errou). O Engine
	// segue o único escritor do Registry.
	if target == session.StateNeedsYou {
		e.reg.SetPendingPrompt(ev.SessionID, ev.Data)
	} else {
		e.reg.ClearPendingPrompt(ev.SessionID)
	}
}

// ensureRunning garante que a sessão exista e esteja em running. Na criação,
// usa os metadados (Machine/Agent/Title) vindos do adapter no session_started —
// mantendo o Engine como único escritor do Registry.
func (e *Engine) ensureRunning(ev event.Event) {
	cur, exists := e.reg.Get(ev.SessionID)
	if !exists {
		now := time.Now()
		e.reg.Add(session.Session{
			ID:        ev.SessionID,
			Machine:   ev.Machine,
			Agent:     ev.Agent,
			Title:     ev.Title,
			State:     session.StateRunning,
			CreatedAt: now,
			UpdatedAt: now,
		})
		return
	}
	if cur.State != session.StateRunning {
		_ = e.reg.UpdateState(ev.SessionID, session.StateRunning)
	}
}

// targetState mapeia um tipo de evento para o estado-alvo. ok=false quando o
// tipo não altera o estado.
func targetState(t event.Type) (session.State, bool) {
	switch t {
	case event.NeedsInput, event.PermissionRequested:
		return session.StateNeedsYou, true
	case event.UserResponded:
		return session.StateRunning, true
	case event.Finished:
		return session.StateDone, true
	case event.Errored:
		return session.StateError, true
	default:
		return "", false
	}
}
