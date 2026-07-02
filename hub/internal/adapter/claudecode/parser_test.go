package claudecode

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// parseAll roda ParseLine em cada linha não-vazia e concatena os eventos.
func parseAll(t *testing.T, data []byte) []event.Event {
	t.Helper()
	var out []event.Event
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		evs, err := ParseLine(line)
		if err != nil {
			t.Fatalf("ParseLine(%s): %v", line, err)
		}
		out = append(out, evs...)
	}
	return out
}

func TestParseInitEmitsSessionStarted(t *testing.T) {
	evs, err := ParseLine([]byte(`{"type":"system","subtype":"init","session_id":"sid-1"}`))
	if err != nil {
		t.Fatalf("ParseLine: %v", err)
	}
	if len(evs) != 1 {
		t.Fatalf("len = %d, quero 1", len(evs))
	}
	if evs[0].Type != event.SessionStarted || evs[0].SessionID != "sid-1" {
		t.Errorf("evento = %+v, quero session_started sid-1", evs[0])
	}
}

func TestParseAssistantText(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"assistant","message":{"content":[{"type":"text","text":"olá mundo"}]}}`))
	if len(evs) != 1 || evs[0].Type != event.OutputChunk || evs[0].Data != "olá mundo" {
		t.Fatalf("evs = %+v, quero um output_chunk \"olá mundo\"", evs)
	}
}

func TestParseAssistantToolUse(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo oi"}}]}}`))
	if len(evs) != 1 || evs[0].Type != event.OutputChunk {
		t.Fatalf("evs = %+v, quero um output_chunk", evs)
	}
	if !strings.HasPrefix(evs[0].Data, "→ Bash:") || !strings.Contains(evs[0].Data, "echo oi") {
		t.Errorf("Data = %q, quero prefixo \"→ Bash:\" contendo o input", evs[0].Data)
	}
}

func TestParseAssistantThinkingIgnored(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}`))
	if len(evs) != 0 {
		t.Errorf("evs = %+v, quero vazio (thinking ignorado)", evs)
	}
}

func TestParseAssistantMultipleBlocks(t *testing.T) {
	// text + thinking + tool_use na mesma linha → 2 eventos (thinking ignorado).
	evs, _ := ParseLine([]byte(`{"type":"assistant","message":{"content":[{"type":"text","text":"vou rodar"},{"type":"thinking","thinking":"x"},{"type":"tool_use","name":"Read","input":{"file":"a.go"}}]}}`))
	if len(evs) != 2 {
		t.Fatalf("len = %d, quero 2", len(evs))
	}
	if evs[0].Data != "vou rodar" || !strings.HasPrefix(evs[1].Data, "→ Read:") {
		t.Errorf("evs = %+v inesperado", evs)
	}
}

func TestParseUserToolResult(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","content":"resultado do comando"}]}}`))
	if len(evs) != 1 || evs[0].Type != event.OutputChunk {
		t.Fatalf("evs = %+v, quero um output_chunk", evs)
	}
	if !strings.HasPrefix(evs[0].Data, "←") || !strings.Contains(evs[0].Data, "resultado do comando") {
		t.Errorf("Data = %q, quero prefixo \"←\" com o resultado", evs[0].Data)
	}
}

func TestParseUserToolResultTruncatedTo120(t *testing.T) {
	long := strings.Repeat("a", 300)
	evs, _ := ParseLine([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","content":"` + long + `"}]}}`))
	if len(evs) != 1 {
		t.Fatalf("len = %d, quero 1", len(evs))
	}
	// "← " + 120 chars
	body := strings.TrimPrefix(evs[0].Data, "← ")
	if len(body) != 120 {
		t.Errorf("corpo com %d chars, quero 120 (truncado)", len(body))
	}
}

func TestParseResultSuccessEmitsFinished(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"result","subtype":"success","is_error":false,"result":"pronto"}`))
	if len(evs) != 1 || evs[0].Type != event.Finished || evs[0].Data != "pronto" {
		t.Fatalf("evs = %+v, quero finished \"pronto\"", evs)
	}
}

func TestParseResultErrorEmitsErrored(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"result","subtype":"error_during_execution","is_error":true,"result":"falhou"}`))
	if len(evs) != 1 || evs[0].Type != event.Errored {
		t.Fatalf("evs = %+v, quero errored", evs)
	}
}

func TestParseIgnoredTypes(t *testing.T) {
	lines := []string{
		`{"type":"system","subtype":"hook_started"}`,
		`{"type":"system","subtype":"hook_response"}`,
		`{"type":"system","subtype":"thinking_tokens"}`,
		`{"type":"rate_limit_event"}`,
		`{"type":"tipo_desconhecido"}`,
	}
	for _, l := range lines {
		evs, err := ParseLine([]byte(l))
		if err != nil {
			t.Errorf("ParseLine(%s) err = %v, quero nil", l, err)
		}
		if len(evs) != 0 {
			t.Errorf("ParseLine(%s) = %+v, quero vazio", l, evs)
		}
	}
}

func TestParseInvalidJSONReturnsError(t *testing.T) {
	if _, err := ParseLine([]byte(`{isso não é json`)); err == nil {
		t.Errorf("ParseLine de JSON inválido err = nil, quero erro")
	}
}

func TestParseFixtureSimple(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "fixture-simple.jsonl"))
	if err != nil {
		t.Fatalf("lendo fixture: %v", err)
	}
	evs := parseAll(t, data)

	wantTypes := []event.Type{event.SessionStarted, event.OutputChunk, event.Finished}
	assertTypes(t, evs, wantTypes)
	if evs[0].SessionID != "ea6c037a-4306-479b-acc7-d5bd0cf52941" {
		t.Errorf("session_id = %q inesperado", evs[0].SessionID)
	}
	if evs[1].Data != "oi" {
		t.Errorf("output = %q, quero \"oi\"", evs[1].Data)
	}
	if evs[2].Data != "oi" {
		t.Errorf("finished Data = %q, quero \"oi\"", evs[2].Data)
	}
}

func TestParseFixtureToolUse(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "fixture-tooluse.jsonl"))
	if err != nil {
		t.Fatalf("lendo fixture: %v", err)
	}
	evs := parseAll(t, data)

	wantTypes := []event.Type{
		event.SessionStarted,
		event.OutputChunk, // tool_use Bash
		event.OutputChunk, // tool_result
		event.OutputChunk, // texto final
		event.Finished,
	}
	assertTypes(t, evs, wantTypes)
	if evs[0].SessionID != "815b221e-73ff-4703-a264-2ac11bcb46c4" {
		t.Errorf("session_id = %q inesperado", evs[0].SessionID)
	}
	if !strings.HasPrefix(evs[1].Data, "→ Bash:") {
		t.Errorf("evs[1].Data = %q, quero tool_use resumido", evs[1].Data)
	}
	if !strings.HasPrefix(evs[2].Data, "←") {
		t.Errorf("evs[2].Data = %q, quero tool_result resumido", evs[2].Data)
	}
}

func assertTypes(t *testing.T, evs []event.Event, want []event.Type) {
	t.Helper()
	if len(evs) != len(want) {
		t.Fatalf("len(eventos) = %d (%+v), quero %d", len(evs), evs, len(want))
	}
	for i, w := range want {
		if evs[i].Type != w {
			t.Errorf("evento[%d].Type = %q, quero %q", i, evs[i].Type, w)
		}
	}
}
