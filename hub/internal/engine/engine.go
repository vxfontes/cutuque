// Package engine é o State Engine: consome eventos normalizados e move cada
// sessão pela máquina de estados (docs/03-modelo-de-estado.md), atualizando o
// Registry. É a única peça que escreve o estado das sessões.
package engine

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// HistoryWriter é o write-through opcional do histórico (Postgres). O Engine —
// único escritor do estado — alimenta cada transição/evento aqui, de forma
// ASSÍNCRONA (fila + goroutine), para o Apply nunca bloquear em I/O de banco.
// Definido aqui (não importa o pacote history) para não inverter a dependência.
type HistoryWriter interface {
	UpsertSession(ctx context.Context, s session.Session) error
	AppendEvent(ctx context.Context, ev event.Event) error
}

// histBuffer é o teto da fila de escrita do histórico. Cheia (Postgres lento/
// fora do ar) → o evento é descartado (best-effort), NUNCA trava o Apply.
const histBuffer = 2048

// histWriteTimeout limita cada escrita no banco para uma conexão pendurada não
// segurar a goroutine de histórico para sempre.
const histWriteTimeout = 5 * time.Second

// Engine aplica eventos ao Registry.
type Engine struct {
	reg      *registry.Registry
	hist     HistoryWriter
	histCh   chan histOp
	histDone chan struct{}
}

// histOp é uma escrita enfileirada: sempre um AppendEvent; upsert=true também
// grava/atualiza a linha da sessão (transições e criação).
type histOp struct {
	ev     event.Event
	upsert bool
}

// New cria um State Engine sobre o Registry dado (sem histórico).
func New(reg *registry.Registry) *Engine {
	return &Engine{reg: reg}
}

// NewWithHistory cria um Engine que faz write-through assíncrono do histórico.
// Chame Close no shutdown para drenar a fila.
func NewWithHistory(reg *registry.Registry, hist HistoryWriter) *Engine {
	e := &Engine{
		reg:      reg,
		hist:     hist,
		histCh:   make(chan histOp, histBuffer),
		histDone: make(chan struct{}),
	}
	go e.histLoop()
	return e
}

// record enfileira uma escrita de histórico (não-bloqueante: fila cheia dropa).
func (e *Engine) record(ev event.Event, upsert bool) {
	if e.hist == nil {
		return
	}
	select {
	case e.histCh <- histOp{ev: ev, upsert: upsert}:
	default:
		slog.Warn("history: fila cheia, evento descartado", "session", ev.SessionID, "type", ev.Type)
	}
}

// histLoop drena a fila e escreve no banco (best-effort; erro só loga).
func (e *Engine) histLoop() {
	defer close(e.histDone)
	for op := range e.histCh {
		ctx, cancel := context.WithTimeout(context.Background(), histWriteTimeout)
		if err := e.hist.AppendEvent(ctx, op.ev); err != nil {
			slog.Warn("history: falha ao gravar evento", "session", op.ev.SessionID, "err", err)
		}
		if op.upsert {
			// Relê a sessão no momento da escrita: reflete o estado já aplicado.
			if s, ok := e.reg.Get(op.ev.SessionID); ok {
				if err := e.hist.UpsertSession(ctx, s); err != nil {
					slog.Warn("history: falha ao gravar sessão", "session", op.ev.SessionID, "err", err)
				}
			}
		}
		cancel()
	}
}

// Close drena a fila de histórico e espera a goroutine terminar (shutdown).
func (e *Engine) Close() {
	if e.hist == nil {
		return
	}
	close(e.histCh)
	<-e.histDone
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
		e.record(ev, true) // cria/atualiza a linha da sessão no histórico
		return
	case event.OutputChunk:
		// Mantém o estado (a sessão segue running); só guarda o output para o
		// stream ao vivo. Ignora output de sessão desconhecida.
		if _, ok := e.reg.Get(ev.SessionID); ok {
			e.reg.AppendOutput(ev.SessionID, ev.Kind, ev.Data)
			e.record(ev, false) // log do output (só append; estado não muda)
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
	e.record(ev, true) // transição de estado → histórico

	// PendingPrompt (o texto que o app exibe): entra em needs_you com o resumo
	// do pedido; some ao sair de needs_you (aprovou/terminou/errou). O Engine
	// segue o único escritor do Registry.
	if target == session.StateNeedsYou {
		e.reg.SetPendingPrompt(ev.SessionID, ev.Data)
		// PendingQuestions (o seletor que o app mostra em vez do sim/não): só
		// quando o pedido é a ferramenta nativa de seleção AskUserQuestion. Nos
		// demais needs_you (permissão comum ou needs_input), garante limpo —
		// senão uma pergunta de seleção anterior "vazaria" pro pedido seguinte.
		if ev.Type == event.PermissionRequested && ev.ToolName == "AskUserQuestion" {
			if qs, ok := parseQuestions(ev.Input); ok {
				e.reg.SetPendingQuestions(ev.SessionID, qs)
			} else {
				e.reg.ClearPendingQuestions(ev.SessionID)
			}
		} else {
			e.reg.ClearPendingQuestions(ev.SessionID)
		}
	} else {
		e.reg.ClearPendingPrompt(ev.SessionID) // já limpa PendingQuestions junto
	}
}

// askUserQuestionsInput espelha o schema de input.questions do AskUserQuestion
// (protocolo verificado na CLI 2.1.198/2.1.206, ver docs/03): cada pergunta tem
// o texto, um header curto, se aceita múltiplas escolhas e as opções (rótulo +
// descrição) que o app oferece à usuária.
type askUserQuestionsInput struct {
	Questions []struct {
		Question    string `json:"question"`
		Header      string `json:"header"`
		MultiSelect bool   `json:"multiSelect"`
		Options     []struct {
			Label       string `json:"label"`
			Description string `json:"description"`
		} `json:"options"`
	} `json:"questions"`
}

// parseQuestions decodifica o input bruto de um AskUserQuestion em
// []session.Question (o formato que o Registry guarda e o app renderiza).
// ok=false se o input não tiver questions (JSON inválido ou array vazio) — o
// chamador trata como "sem seleção disponível" (limpa PendingQuestions).
func parseQuestions(raw json.RawMessage) ([]session.Question, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	var in askUserQuestionsInput
	if err := json.Unmarshal(raw, &in); err != nil || len(in.Questions) == 0 {
		return nil, false
	}
	qs := make([]session.Question, 0, len(in.Questions))
	for _, q := range in.Questions {
		opts := make([]session.QuestionOption, 0, len(q.Options))
		for _, o := range q.Options {
			opts = append(opts, session.QuestionOption{Label: o.Label, Description: o.Description})
		}
		qs = append(qs, session.Question{
			Question:    q.Question,
			Header:      q.Header,
			MultiSelect: q.MultiSelect,
			Options:     opts,
		})
	}
	return qs, true
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
		Model:     ev.Model,
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
