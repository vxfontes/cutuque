package engine

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// seed adiciona uma sessão num estado inicial para os testes de transição.
func seed(reg *registry.Registry, id string, st session.State) {
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: id, Machine: "macbook", Agent: "claude-code", Title: "t", State: st, CreatedAt: now, UpdatedAt: now})
}

func TestApplySessionStartedCreatesRunningSession(t *testing.T) {
	reg := registry.New()
	eng := New(reg)

	eng.Apply(event.Event{SessionID: "novo", Type: event.SessionStarted})

	got, ok := reg.Get("novo")
	if !ok {
		t.Fatalf("sessão não foi criada")
	}
	if got.State != session.StateRunning {
		t.Errorf("State = %q, quero \"running\"", got.State)
	}
}

func TestApplyTransitionsTable(t *testing.T) {
	cases := []struct {
		name string
		from session.State
		ev   event.Type
		want session.State
	}{
		{"running+output => running", session.StateRunning, event.OutputChunk, session.StateRunning},
		{"running+needs_input => needs_you", session.StateRunning, event.NeedsInput, session.StateNeedsYou},
		{"running+permission => needs_you", session.StateRunning, event.PermissionRequested, session.StateNeedsYou},
		{"running+finished => done", session.StateRunning, event.Finished, session.StateDone},
		{"running+errored => error", session.StateRunning, event.Errored, session.StateError},
		{"needs_you+finished => done", session.StateNeedsYou, event.Finished, session.StateDone},
		{"needs_you+user_responded => running", session.StateNeedsYou, event.UserResponded, session.StateRunning},
		{"done+session_started => running", session.StateDone, event.SessionStarted, session.StateRunning},
		{"idle+session_started => running", session.StateIdle, event.SessionStarted, session.StateRunning},
		{"error+session_started => running", session.StateError, event.SessionStarted, session.StateRunning},

		// Redundantes / ilegais: não quebram, mantêm o estado.
		{"done+finished => done (redundante)", session.StateDone, event.Finished, session.StateDone},
		{"error+errored => error (redundante)", session.StateError, event.Errored, session.StateError},
		{"needs_you+needs_input => needs_you (redundante)", session.StateNeedsYou, event.NeedsInput, session.StateNeedsYou},

		// Regra de desempate: na dúvida, prefira needs_you (mesmo vindo de done).
		{"done+needs_input => needs_you (desempate)", session.StateDone, event.NeedsInput, session.StateNeedsYou},
		{"done+permission => needs_you (desempate)", session.StateDone, event.PermissionRequested, session.StateNeedsYou},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reg := registry.New()
			eng := New(reg)
			seed(reg, "s", c.from)

			eng.Apply(event.Event{SessionID: "s", Type: c.ev})

			got, _ := reg.Get("s")
			if got.State != c.want {
				t.Errorf("de %q com %q => %q, quero %q", c.from, c.ev, got.State, c.want)
			}
		})
	}
}

func TestApplyOutputChunkAppendsOutputKeepsRunning(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)

	eng.Apply(event.Event{SessionID: "s", Type: event.OutputChunk, Kind: event.KindAssistant, Data: "linha de log"})

	got, _ := reg.Get("s")
	if got.State != session.StateRunning {
		t.Errorf("State = %q, quero \"running\"", got.State)
	}
	out := reg.Output("s")
	if len(out) != 1 || out[0].Kind != event.KindAssistant || out[0].Text != "linha de log" {
		t.Errorf("Output = %+v, quero [{assistant, \"linha de log\"}]", out)
	}
}

func TestApplyOutputChunkUnknownSessionStoresNothing(t *testing.T) {
	reg := registry.New()
	eng := New(reg)

	eng.Apply(event.Event{SessionID: "fantasma", Type: event.OutputChunk, Data: "x"})

	if out := reg.Output("fantasma"); len(out) != 0 {
		t.Errorf("Output = %v, quero vazio para sessão desconhecida", out)
	}
}

func TestApplyUnknownSessionIsIgnored(t *testing.T) {
	reg := registry.New()
	eng := New(reg)

	// Eventos de transição para sessão inexistente não devem criar nada nem entrar em pânico.
	for _, ty := range []event.Type{event.OutputChunk, event.NeedsInput, event.Finished, event.Errored} {
		eng.Apply(event.Event{SessionID: "fantasma", Type: ty})
	}

	if _, ok := reg.Get("fantasma"); ok {
		t.Errorf("sessão fantasma não deveria existir")
	}
}

func TestApplyPermissionSetsPendingPrompt(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)

	eng.Apply(event.Event{SessionID: "s", Type: event.PermissionRequested, Data: "Bash: touch x.txt — Create empty probe file", ControlID: "req-1"})

	got, _ := reg.Get("s")
	if got.State != session.StateNeedsYou {
		t.Fatalf("State = %q, quero \"needs_you\"", got.State)
	}
	if got.PendingPrompt != "Bash: touch x.txt — Create empty probe file" {
		t.Errorf("PendingPrompt = %q, quero o resumo do pedido", got.PendingPrompt)
	}
}

func TestApplyNeedsInputSetsPendingPrompt(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)

	eng.Apply(event.Event{SessionID: "s", Type: event.NeedsInput, Data: "posso continuar?"})

	if got, _ := reg.Get("s"); got.PendingPrompt != "posso continuar?" {
		t.Errorf("PendingPrompt = %q, quero a pergunta", got.PendingPrompt)
	}
}

func TestApplyUserRespondedClearsPendingPrompt(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)
	eng.Apply(event.Event{SessionID: "s", Type: event.PermissionRequested, Data: "algo perigoso"})

	eng.Apply(event.Event{SessionID: "s", Type: event.UserResponded})

	got, _ := reg.Get("s")
	if got.State != session.StateRunning {
		t.Errorf("State = %q, quero \"running\" após user_responded", got.State)
	}
	if got.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio ao sair de needs_you", got.PendingPrompt)
	}
}

func TestApplyFinishedClearsPendingPrompt(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)
	eng.Apply(event.Event{SessionID: "s", Type: event.NeedsInput, Data: "pergunta"})

	eng.Apply(event.Event{SessionID: "s", Type: event.Finished})

	if got, _ := reg.Get("s"); got.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio após finished", got.PendingPrompt)
	}
}

func TestApplyRedundantDoesNotBumpUpdatedAt(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateDone)
	before, _ := reg.Get("s")

	eng.Apply(event.Event{SessionID: "s", Type: event.Finished}) // done+finished: no-op

	after, _ := reg.Get("s")
	if !after.UpdatedAt.Equal(before.UpdatedAt) {
		t.Errorf("UpdatedAt mudou num no-op: %v -> %v", before.UpdatedAt, after.UpdatedAt)
	}
}

// TestRunnerReclaimsHookPreCreatedSession cobre a corrida do review #1: um hook
// pré-cria a sessão como external; quando o Runner (autoritativo, External:false)
// manda o session_started, o hub reassume — External vira false (aprovar/negar
// volta a funcionar).
func TestRunnerReclaimsHookPreCreatedSession(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	id := "sess-race"

	// hook chega primeiro: cria external.
	eng.EnsureRegistered(id, "macbook", "claude-code", "titulo-hook", "/x", "")
	if s, _ := reg.Get(id); !s.External {
		t.Fatalf("pré-condição: sessão deveria estar external após o hook")
	}

	// Runner manda o session_started dele (External:false = autoritativo).
	eng.Apply(event.Event{SessionID: id, Type: event.SessionStarted, Machine: "macbook", Agent: "claude-code", Title: "prompt-real", At: time.Now()})

	s, _ := reg.Get(id)
	if s.External {
		t.Error("sessão continuou external — o Runner deveria ter reassumido (aprovar/negar ficaria escondido)")
	}
	if s.Title != "prompt-real" {
		t.Errorf("Title = %q, quero o do Runner \"prompt-real\"", s.Title)
	}
}

// TestApplyAskUserQuestionSetsPendingQuestions cobre o fluxo da pergunta de
// seleção nativa (AskUserQuestion): o Engine parseia ev.Input (o array
// `questions` do control_request) e preenche PendingQuestions, junto do
// PendingPrompt de fallback — o app troca o sim/não pelo seletor quando
// PendingQuestions não está vazio.
func TestApplyAskUserQuestionSetsPendingQuestions(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)

	input := `{"questions":[{"question":"Qual cor você prefere?","header":"Cor","multiSelect":false,"options":[{"label":"Vermelho","description":"Cor quente"},{"label":"Azul","description":"Cor fria"}]}]}`
	eng.Apply(event.Event{
		SessionID: "s",
		Type:      event.PermissionRequested,
		Data:      "Pergunta: Qual cor você prefere?",
		ControlID: "req-1",
		ToolName:  "AskUserQuestion",
		ToolUseID: "toolu_1",
		Input:     json.RawMessage(input),
	})

	got, _ := reg.Get("s")
	if got.State != session.StateNeedsYou {
		t.Fatalf("State = %q, quero needs_you", got.State)
	}
	if len(got.PendingQuestions) != 1 {
		t.Fatalf("PendingQuestions = %+v, quero 1 pergunta", got.PendingQuestions)
	}
	q := got.PendingQuestions[0]
	if q.Question != "Qual cor você prefere?" || q.Header != "Cor" || q.MultiSelect {
		t.Errorf("Question = %+v inesperado", q)
	}
	if len(q.Options) != 2 || q.Options[0].Label != "Vermelho" || q.Options[0].Description != "Cor quente" {
		t.Errorf("Options = %+v inesperado", q.Options)
	}
}

// TestApplyPlainPermissionClearsPendingQuestions cobre o caso comum (Bash etc):
// um pedido de permissão normal NÃO é AskUserQuestion, então PendingQuestions
// deve ficar vazio — mesmo que a sessão tivesse uma pergunta pendente antes.
func TestApplyPlainPermissionClearsPendingQuestions(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)

	// 1ª pergunta de seleção pendente.
	eng.Apply(event.Event{
		SessionID: "s", Type: event.PermissionRequested, ToolName: "AskUserQuestion",
		Input: json.RawMessage(`{"questions":[{"question":"q?","options":[{"label":"a"}]}]}`),
	})
	if got, _ := reg.Get("s"); len(got.PendingQuestions) == 0 {
		t.Fatalf("pré-condição: PendingQuestions deveria estar preenchido")
	}

	// Usuária responde, e o próximo pedido é um Bash comum (não AskUserQuestion).
	eng.Apply(event.Event{SessionID: "s", Type: event.UserResponded})
	eng.Apply(event.Event{SessionID: "s", Type: event.PermissionRequested, Data: "Bash: touch x.txt", ToolName: "Bash"})

	got, _ := reg.Get("s")
	if len(got.PendingQuestions) != 0 {
		t.Errorf("PendingQuestions = %+v, quero vazio (pedido comum de permissão)", got.PendingQuestions)
	}
	if got.PendingPrompt != "Bash: touch x.txt" {
		t.Errorf("PendingPrompt = %q inesperado", got.PendingPrompt)
	}
}

// TestApplyUserRespondedClearsPendingQuestions cobre a saída de needs_you: ao
// responder, PendingQuestions some junto do PendingPrompt (ClearPendingPrompt
// limpa os dois).
func TestApplyUserRespondedClearsPendingQuestions(t *testing.T) {
	reg := registry.New()
	eng := New(reg)
	seed(reg, "s", session.StateRunning)
	eng.Apply(event.Event{
		SessionID: "s", Type: event.PermissionRequested, ToolName: "AskUserQuestion",
		Input: json.RawMessage(`{"questions":[{"question":"q?","options":[{"label":"a"}]}]}`),
	})

	eng.Apply(event.Event{SessionID: "s", Type: event.UserResponded})

	got, _ := reg.Get("s")
	if len(got.PendingQuestions) != 0 {
		t.Errorf("PendingQuestions = %+v, quero vazio após user_responded", got.PendingQuestions)
	}
}

// TestSetPaneEvictsStaleSession cobre o review #3: quando uma pane é reusada por
// uma sessão nova, a sessão antiga perde a pane e, se estava em needs_you, vira
// done (senão tocar nela abriria o terminal da sessão nova).
func TestSetPaneEvictsStaleSession(t *testing.T) {
	reg := registry.New()
	now := time.Now()
	pane := "/tmp/tmux-501/main\t%0"
	// A: stale, travada em needs_you, com a pane.
	reg.Add(session.Session{ID: "A", Machine: "macbook", State: session.StateNeedsYou, Pane: pane, PendingPrompt: "?", CreatedAt: now, UpdatedAt: now})
	// B: nova, reusa a MESMA pane.
	reg.Add(session.Session{ID: "B", Machine: "macbook", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	reg.SetPane("B", pane)

	a, _ := reg.Get("A")
	if a.Pane == pane {
		t.Error("A ainda tem a pane reusada — deveria ter sido despejada")
	}
	if a.State != session.StateDone {
		t.Errorf("A.State = %q, quero done (stale despejada)", a.State)
	}
	b, _ := reg.Get("B")
	if b.Pane != pane {
		t.Errorf("B deveria ter a pane; got %q", b.Pane)
	}
}

// TestSetPaneDoesNotEvictCrossMachine: o mesmo alvo de pane em máquinas
// DIFERENTES não colide — defaults do tmux coincidem entre máquinas, mas cada
// uma é um terminal distinto (review SEC-104).
func TestSetPaneDoesNotEvictCrossMachine(t *testing.T) {
	reg := registry.New()
	now := time.Now()
	pane := "/tmp/tmux-501/main\t%0" // mesmo alvo, máquinas distintas
	reg.Add(session.Session{ID: "A", Machine: "macbook", State: session.StateNeedsYou, Pane: pane, PendingPrompt: "?", CreatedAt: now, UpdatedAt: now})
	reg.Add(session.Session{ID: "B", Machine: "wsl", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	reg.SetPane("B", pane)

	// A (macbook) NÃO deve ter sido despejada por B (wsl).
	if a, _ := reg.Get("A"); a.Pane != pane || a.State != session.StateNeedsYou {
		t.Errorf("A (macbook) foi mexida por uma pane igual em outra máquina: %+v", a)
	}
}
