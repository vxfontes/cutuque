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
//   - needs_input / permission_requested: → needs_you.
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
		e.ensureRunning(ev.SessionID)
		return
	case event.OutputChunk:
		// Mantém o estado (a sessão segue running); só guarda o output para o
		// stream ao vivo. Ignora output de sessão desconhecida.
		if _, ok := e.reg.Get(ev.SessionID); ok {
			e.reg.AppendOutput(ev.SessionID, ev.Data)
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
	if cur.State == target {
		return // redundante: no-op (não mexe em UpdatedAt nem faz broadcast)
	}
	_ = e.reg.UpdateState(ev.SessionID, target)
}

// ensureRunning garante que a sessão exista e esteja em running.
func (e *Engine) ensureRunning(id string) {
	cur, exists := e.reg.Get(id)
	if !exists {
		now := time.Now()
		e.reg.Add(session.Session{
			ID:        id,
			State:     session.StateRunning,
			CreatedAt: now,
			UpdatedAt: now,
		})
		return
	}
	if cur.State != session.StateRunning {
		_ = e.reg.UpdateState(id, session.StateRunning)
	}
}

// targetState mapeia um tipo de evento para o estado-alvo. ok=false quando o
// tipo não altera o estado.
func targetState(t event.Type) (session.State, bool) {
	switch t {
	case event.NeedsInput, event.PermissionRequested:
		return session.StateNeedsYou, true
	case event.Finished:
		return session.StateDone, true
	case event.Errored:
		return session.StateError, true
	default:
		return "", false
	}
}
