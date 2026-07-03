package claudecode

import (
	"bytes"
	"encoding/json"
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
	if evs[0].Kind != event.KindAssistant {
		t.Errorf("Kind = %q, quero %q", evs[0].Kind, event.KindAssistant)
	}
}

func TestParseAssistantToolUse(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo oi"}}]}}`))
	if len(evs) != 1 || evs[0].Type != event.OutputChunk {
		t.Fatalf("evs = %+v, quero um output_chunk", evs)
	}
	if evs[0].Kind != event.KindTool {
		t.Errorf("Kind = %q, quero %q", evs[0].Kind, event.KindTool)
	}
	if evs[0].Data != "Bash: echo oi" {
		t.Errorf("Data = %q, quero \"Bash: echo oi\" (sem prefixo →)", evs[0].Data)
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
	if evs[0].Kind != event.KindAssistant || evs[0].Data != "vou rodar" {
		t.Errorf("evs[0] = %+v inesperado", evs[0])
	}
	if evs[1].Kind != event.KindTool || !strings.HasPrefix(evs[1].Data, "Read:") {
		t.Errorf("evs[1] = %+v inesperado", evs[1])
	}
}

func TestParseUserToolResult(t *testing.T) {
	evs, _ := ParseLine([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","content":"resultado do comando"}]}}`))
	if len(evs) != 1 || evs[0].Type != event.OutputChunk {
		t.Fatalf("evs = %+v, quero um output_chunk", evs)
	}
	if evs[0].Kind != event.KindToolResult {
		t.Errorf("Kind = %q, quero %q", evs[0].Kind, event.KindToolResult)
	}
	if evs[0].Data != "resultado do comando" {
		t.Errorf("Data = %q, quero o resultado sem prefixo ←", evs[0].Data)
	}
}

func TestParseUserToolResultTruncatedTo200(t *testing.T) {
	long := strings.Repeat("a", 300)
	evs, _ := ParseLine([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","content":"` + long + `"}]}}`))
	if len(evs) != 1 {
		t.Fatalf("len = %d, quero 1", len(evs))
	}
	if len(evs[0].Data) != 200 {
		t.Errorf("corpo com %d chars, quero 200 (truncado)", len(evs[0].Data))
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

func TestParseControlRequestEmitsPermission(t *testing.T) {
	line := []byte(`{"type":"control_request","request_id":"req-abc","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch x.txt","description":"Create empty probe file"},"description":"Create empty probe file"}}`)
	evs, err := ParseLine(line)
	if err != nil {
		t.Fatalf("ParseLine: %v", err)
	}
	if len(evs) != 1 || evs[0].Type != event.PermissionRequested {
		t.Fatalf("evs = %+v, quero um permission_requested", evs)
	}
	e := evs[0]
	if e.ControlID != "req-abc" {
		t.Errorf("ControlID = %q, quero \"req-abc\"", e.ControlID)
	}
	if !strings.HasPrefix(e.Data, "Bash: touch x.txt") || !strings.Contains(e.Data, "Create empty probe file") {
		t.Errorf("Data = %q, quero resumo \"Bash: touch x.txt — Create empty probe file\"", e.Data)
	}
	// Input original preservado para o updatedInput do allow.
	var in struct {
		Command string `json:"command"`
	}
	if err := json.Unmarshal(e.Input, &in); err != nil || in.Command != "touch x.txt" {
		t.Errorf("Input = %s, quero conter o command original", e.Input)
	}
}

func TestParseControlRequestOtherSubtypeIgnored(t *testing.T) {
	line := []byte(`{"type":"control_request","request_id":"r","request":{"subtype":"initialize"}}`)
	evs, err := ParseLine(line)
	if err != nil {
		t.Fatalf("ParseLine: %v", err)
	}
	if len(evs) != 0 {
		t.Errorf("evs = %+v, quero vazio (subtype não-permissão)", evs)
	}
}

func TestParseControlFixtureHasPermission(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "fixture-control.jsonl"))
	if err != nil {
		t.Fatalf("lendo fixture: %v", err)
	}
	evs := parseAll(t, data)

	var perm *event.Event
	for i := range evs {
		if evs[i].Type == event.PermissionRequested {
			perm = &evs[i]
			break
		}
	}
	if perm == nil {
		t.Fatalf("fixture-control não produziu permission_requested: %+v", evs)
	}
	if perm.ControlID != "553dacfc-a6e3-45f6-b37d-98f5cf4d258b" {
		t.Errorf("ControlID = %q, quero o request_id da fixture", perm.ControlID)
	}
	if !strings.HasPrefix(perm.Data, "Bash:") {
		t.Errorf("Data = %q, quero prefixo \"Bash:\"", perm.Data)
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
	if evs[1].Kind != event.KindTool || !strings.HasPrefix(evs[1].Data, "Bash:") {
		t.Errorf("evs[1] = %+v, quero kind \"tool\" com \"Bash:\"", evs[1])
	}
	if evs[2].Kind != event.KindToolResult {
		t.Errorf("evs[2] = %+v, quero kind \"tool_result\"", evs[2])
	}
	if evs[3].Kind != event.KindAssistant {
		t.Errorf("evs[3] = %+v, quero kind \"assistant\"", evs[3])
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
