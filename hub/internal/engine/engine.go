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
	now := time.Now()
	// Reivindicação atômica (checa presença + insere no MESMO lock): fecha a
	// corrida entre Get e Add quando hook e Runner criam a MESMA sessão nova ao
	// mesmo tempo — um Add bruto sobrescreveria silenciosamente o estado que o
	// outro já avançou (ex.: needs_you + PendingPrompt), deixando o processo real
	// travado sem badge visível (review SEC-106, mesmo padrão do SEC-103).
	cur, added := e.reg.AddIfAbsent(session.Session{
		ID:        ev.SessionID,
		Machine:   ev.Machine,
		Agent:     ev.Agent,
		Title:     ev.Title,
		State:     session.StateRunning,
		Cwd:       ev.Cwd,
		Pane:      ev.Pane,
		External:  ev.External,
		CreatedAt: now,
		UpdatedAt: now,
	})
	if added {
		return
	}
	// Já existia (re-disparo ou corrida): reconcilia sem sobrescrever.
	// Se o evento é do Runner (autoritativo, !External) e a sessão foi
	// pré-criada como external por um hook, o hub reassume o controle dela
	// (senão aprovar/negar ficaria escondido pra sempre — #1).
	if !ev.External && cur.External {
		e.reg.Reclaim(ev.SessionID, ev.Title, ev.Machine, ev.Agent)
	}
	if cur.State != session.StateRunning {
		_ = e.reg.UpdateState(ev.SessionID, session.StateRunning)
	}
	e.reg.SetPane(ev.SessionID, ev.Pane)
}

// SetPane atualiza o alvo tmux de uma sessão existente (usado pelos hooks para
// gravar o pane numa sessão que já foi registrada antes de o pane ser conhecido).
func (e *Engine) SetPane(id, pane string) { e.reg.SetPane(id, pane) }

// EnsureRegistered registra a sessão (como running) se ela ainda NÃO existir —
// usado pelos hooks do Claude Code para que QUALQUER sessão no Mac (não só as
// lançadas pelo hub) apareça e possa cutucar. No-op se já conhecida (não mexe
// no estado atual). machine/agent vazios ganham defaults.
func (e *Engine) EnsureRegistered(id, machine, agent, title, cwd, pane string) {
	if id == "" {
		return
	}
	if machine == "" {
		machine = "mac"
	}
	if agent == "" {
		agent = "claude-code"
	}
	now := time.Now()
	// Reivindicação atômica (checa dismissed + insere no MESMO lock): fecha a
	// corrida entre Get/Dismissed/Add e o Undismiss+AddIfAbsent do Adopt (#2).
	e.reg.AddIfAllowed(session.Session{
		ID:        id,
		Machine:   machine,
		Agent:     agent,
		Title:     title,
		State:     session.StateRunning,
		Cwd:       cwd,
		Pane:      pane,
		External:  true, // veio de hook — o hub não controla o gate dela
		CreatedAt: now,
		UpdatedAt: now,
	})
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
