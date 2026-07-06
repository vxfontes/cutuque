package codex

import (
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// oneEvent parseia uma linha e exige exatamente um evento.
func oneEvent(t *testing.T, line string) event.Event {
	t.Helper()
	evs, err := ParseLine([]byte(line))
	if err != nil {
		t.Fatalf("ParseLine erro: %v", err)
	}
	if len(evs) != 1 {
		t.Fatalf("len(evs) = %d, quero 1 (%q)", len(evs), line)
	}
	return evs[0]
}

func TestThreadStartedViraSessionStarted(t *testing.T) {
	e := oneEvent(t, `{"type":"thread.started","thread_id":"019f37bf-ca73-7f73-9a53-249cd15a812b"}`)
	if e.Type != event.SessionStarted {
		t.Errorf("Type = %q, quero session_started", e.Type)
	}
	if e.SessionID != "019f37bf-ca73-7f73-9a53-249cd15a812b" {
		t.Errorf("SessionID = %q", e.SessionID)
	}
}

func TestAgentMessageViraChunkAssistant(t *testing.T) {
	e := oneEvent(t, `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pronto"}}`)
	if e.Type != event.OutputChunk || e.Kind != event.KindAssistant {
		t.Fatalf("Type/Kind = %q/%q, quero output_chunk/assistant", e.Type, e.Kind)
	}
	if e.Data != "pronto" {
		t.Errorf("Data = %q, quero \"pronto\"", e.Data)
	}
}

func TestTurnCompletedViraFinished(t *testing.T) {
	e := oneEvent(t, `{"type":"turn.completed","usage":{"input_tokens":10}}`)
	if e.Type != event.Finished {
		t.Errorf("Type = %q, quero finished", e.Type)
	}
}

func TestTurnFailedViraErrored(t *testing.T) {
	e := oneEvent(t, `{"type":"turn.failed","error":{"message":"estourou o limite"}}`)
	if e.Type != event.Errored {
		t.Errorf("Type = %q, quero errored", e.Type)
	}
	if e.Data != "estourou o limite" {
		t.Errorf("Data = %q, quero a mensagem do erro", e.Data)
	}
}

func TestCommandExecutionViraToolEToolResult(t *testing.T) {
	evs, err := ParseLine([]byte(`{"type":"item.completed","item":{"type":"command_execution","command":"ls -la","aggregated_output":"a.txt\nb.txt"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 2 {
		t.Fatalf("len(evs) = %d, quero 2 (tool + tool_result)", len(evs))
	}
	if evs[0].Kind != event.KindTool || evs[0].Data != "$ ls -la" {
		t.Errorf("evs[0] = %q/%q", evs[0].Kind, evs[0].Data)
	}
	if evs[1].Kind != event.KindToolResult {
		t.Errorf("evs[1].Kind = %q, quero tool_result", evs[1].Kind)
	}
}

func TestReasoningEUserMessageSaoIgnorados(t *testing.T) {
	for _, line := range []string{
		`{"type":"item.completed","item":{"type":"reasoning","text":"pensando..."}}`,
		`{"type":"item.completed","item":{"type":"user_message","message":"oi"}}`,
		`{"type":"turn.started"}`,
		`{"type":"item.started","item":{"type":"agent_message"}}`,
	} {
		evs, err := ParseLine([]byte(line))
		if err != nil {
			t.Fatalf("ParseLine erro: %v (%q)", err, line)
		}
		if len(evs) != 0 {
			t.Errorf("len(evs) = %d, quero 0 para %q", len(evs), line)
		}
	}
}

func TestItemDesconhecidoNaoSomeSilenciosamente(t *testing.T) {
	e := oneEvent(t, `{"type":"item.completed","item":{"type":"mystery_widget","text":"algo aconteceu"}}`)
	if e.Type != event.OutputChunk || e.Kind != event.KindTool {
		t.Fatalf("Type/Kind = %q/%q, quero output_chunk/tool", e.Type, e.Kind)
	}
	if e.Data == "" {
		t.Error("Data vazio: item desconhecido sumiu silenciosamente")
	}
}

func TestLinhaNaoJSONNaoQuebra(t *testing.T) {
	evs, err := ParseLine([]byte("Reading additional input from stdin...\n"))
	if err != nil {
		t.Fatalf("erro em linha não-JSON: %v", err)
	}
	if len(evs) != 0 {
		t.Errorf("len(evs) = %d, quero 0", len(evs))
	}
}
