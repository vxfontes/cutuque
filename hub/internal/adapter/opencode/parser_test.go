package opencode

import (
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// feed roda uma sequência de linhas por UM parser (com estado) e devolve todos
// os eventos, para checar o comportamento de "session_started só uma vez".
func feed(t *testing.T, lines ...string) []event.Event {
	t.Helper()
	p := newParser()
	var all []event.Event
	for _, ln := range lines {
		evs, err := p([]byte(ln))
		if err != nil {
			t.Fatalf("parse %q: %v", ln, err)
		}
		all = append(all, evs...)
	}
	return all
}

func countType(evs []event.Event, tp event.Type) int {
	n := 0
	for _, e := range evs {
		if e.Type == tp {
			n++
		}
	}
	return n
}

func TestPrimeiroEventoSintetizaSessionStartedUmaVez(t *testing.T) {
	evs := feed(t,
		`{"type":"step_start","sessionID":"ses_ABC123def","part":{"type":"step-start"}}`,
		`{"type":"text","sessionID":"ses_ABC123def","part":{"type":"text","text":"oi"}}`,
	)
	if n := countType(evs, event.SessionStarted); n != 1 {
		t.Fatalf("SessionStarted = %d, quero exatamente 1", n)
	}
	if evs[0].Type != event.SessionStarted || evs[0].SessionID != "ses_ABC123def" {
		t.Errorf("1o evento = %+v, quero SessionStarted ses_ABC123def", evs[0])
	}
}

func TestTextViraAssistant(t *testing.T) {
	evs := feed(t, `{"type":"text","sessionID":"ses_x1","part":{"type":"text","text":"pronto"}}`)
	// [SessionStarted, OutputChunk]
	last := evs[len(evs)-1]
	if last.Type != event.OutputChunk || last.Kind != event.KindAssistant || last.Data != "pronto" {
		t.Errorf("último = %+v, quero output_chunk/assistant 'pronto'", last)
	}
}

func TestToolUseViraToolEToolResult(t *testing.T) {
	evs := feed(t, `{"type":"tool_use","sessionID":"ses_x1","part":{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"/tmp/a.txt"},"output":"conteudo do arquivo"}}}`)
	// pula o SessionStarted; procura tool + tool_result
	if countType(evs, event.OutputChunk) != 2 {
		t.Fatalf("chunks = %d, quero 2 (tool + tool_result): %+v", countType(evs, event.OutputChunk), evs)
	}
	var tool, res event.Event
	for _, e := range evs {
		if e.Kind == event.KindTool {
			tool = e
		}
		if e.Kind == event.KindToolResult {
			res = e
		}
	}
	if tool.Data != "read: /tmp/a.txt" {
		t.Errorf("tool.Data = %q, quero 'read: /tmp/a.txt'", tool.Data)
	}
	if res.Data == "" {
		t.Error("tool_result vazio")
	}
}

func TestStepFinishStopFinaliza(t *testing.T) {
	evs := feed(t, `{"type":"step_finish","sessionID":"ses_x1","part":{"type":"step-finish","reason":"stop"}}`)
	if countType(evs, event.Finished) != 1 {
		t.Errorf("Finished = %d, quero 1 (reason stop)", countType(evs, event.Finished))
	}
}

func TestStepFinishToolCallsNaoFinaliza(t *testing.T) {
	evs := feed(t, `{"type":"step_finish","sessionID":"ses_x1","part":{"type":"step-finish","reason":"tool-calls"}}`)
	if countType(evs, event.Finished) != 0 {
		t.Errorf("Finished = %d, quero 0 (reason tool-calls continua)", countType(evs, event.Finished))
	}
}

func TestErrorViraErrored(t *testing.T) {
	evs := feed(t, `{"type":"error","sessionID":"ses_x1","error":{"name":"UnknownError","data":{"message":"Model not found"}}}`)
	if countType(evs, event.Errored) != 1 {
		t.Fatalf("Errored = %d, quero 1", countType(evs, event.Errored))
	}
	var er event.Event
	for _, e := range evs {
		if e.Type == event.Errored {
			er = e
		}
	}
	if er.Data != "Model not found" {
		t.Errorf("Errored.Data = %q, quero 'Model not found'", er.Data)
	}
}

func TestLinhaNaoJSONNaoQuebra(t *testing.T) {
	evs := feed(t, "algum log solto\n")
	if len(evs) != 0 {
		t.Errorf("len = %d, quero 0", len(evs))
	}
}