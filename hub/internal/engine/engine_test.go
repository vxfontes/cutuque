package engine

import (
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
