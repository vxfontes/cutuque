// Package opencode adapta o OpenCode CLI (opencode.ai) ao contrato de agente do
// Cutuque, reusando a plataforma de execução do pacote agent (Handle, Runner,
// Target). Mesma forma do Codex: one-shot streaming.
//
// `opencode run --format json [-s <id>] "<prompt>"` transmite eventos JSONL no
// stdout e sai ao fim do turno. Cada reply é um novo `run -s <id>` (não há stdin
// bidirecional). O parser aqui traduz esses eventos nos event.Event normalizados.
package opencode

import (
	"encoding/json"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/event"
)

const maxChunk = 4000

// ocEvent é um evento do `opencode run --format json`. Todo evento carrega
// sessionID; a "parte" (part) traz o conteúdo conforme o tipo.
type ocEvent struct {
	Type      string          `json:"type"`
	SessionID string          `json:"sessionID"`
	Part      json.RawMessage `json:"part"`
	Error     json.RawMessage `json:"error"`
}

type ocPart struct {
	Type   string      `json:"type"`
	Text   string      `json:"text"`
	Tool   string      `json:"tool"`
	Reason string      `json:"reason"` // step_finish: "tool-calls" (continua) vs "stop"/etc (fim)
	State  ocToolState `json:"state"`
}

type ocToolState struct {
	Status string          `json:"status"`
	Input  json.RawMessage `json:"input"`
	Output string          `json:"output"`
}

// newParser cria um parser COM ESTADO por run: o OpenCode não emite um evento
// "session_started" próprio, então sintetizamos um SessionStarted no PRIMEIRO
// evento que traz um sessionID (o Launch depende dele, e o Engine cria a sessão
// a partir dele). O estado `started` garante que só o primeiro dispare.
func newParser() agent.ParseFunc {
	started := false
	return func(line []byte) ([]event.Event, error) {
		return parseLine(line, &started)
	}
}

func parseLine(line []byte, started *bool) ([]event.Event, error) {
	trimmed := strings.TrimSpace(string(line))
	if trimmed == "" {
		return nil, nil
	}
	var ev ocEvent
	if err := json.Unmarshal([]byte(trimmed), &ev); err != nil {
		return nil, nil // linha não-JSON (log solto) — ignora
	}

	var out []event.Event
	// Sintetiza o session_started no primeiro evento com sessionID.
	if !*started && ev.SessionID != "" {
		*started = true
		out = append(out, event.Event{Type: event.SessionStarted, SessionID: ev.SessionID})
	}

	switch ev.Type {
	case "error":
		out = append(out, event.Event{Type: event.Errored, SessionID: ev.SessionID, Data: ocErr(ev.Error)})
	case "text", "tool_use", "step_finish":
		out = append(out, partEvents(ev)...)
	}
	return out, nil
}

func partEvents(ev ocEvent) []event.Event {
	var p ocPart
	if len(ev.Part) > 0 {
		_ = json.Unmarshal(ev.Part, &p)
	}
	switch ev.Type {
	case "text":
		if strings.TrimSpace(p.Text) != "" {
			return []event.Event{chunk(ev.SessionID, event.KindAssistant, p.Text)}
		}
	case "tool_use":
		return toolEvents(ev.SessionID, p)
	case "step_finish":
		// "tool-calls" = mais passos vêm; qualquer outro (stop/length/…) = o turno
		// terminou. OpenCode é one-shot: o processo sai logo depois.
		if p.Reason != "" && p.Reason != "tool-calls" {
			return []event.Event{{Type: event.Finished, SessionID: ev.SessionID}}
		}
	}
	return nil
}

func toolEvents(sid string, p ocPart) []event.Event {
	name := p.Tool
	if name == "" {
		name = "ferramenta"
	}
	summary := name
	if detail := toolInput(p.State.Input); detail != "" {
		summary = name + ": " + detail
	}
	out := []event.Event{chunk(sid, event.KindTool, summary)}
	if p.State.Output != "" {
		out = append(out, chunk(sid, event.KindToolResult, trunc(p.State.Output)))
	}
	return out
}

// toolInput extrai um resumo curto do input da ferramenta (prefere caminhos/cmd).
func toolInput(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return ""
	}
	for _, k := range []string{"filePath", "command", "pattern", "path", "query"} {
		if v, ok := m[k].(string); ok && v != "" {
			return truncN(v, 120)
		}
	}
	b, _ := json.Marshal(m)
	return truncN(string(b), 120)
}

func chunk(sid, kind, data string) event.Event {
	return event.Event{Type: event.OutputChunk, SessionID: sid, Kind: kind, Data: data}
}

func ocErr(raw json.RawMessage) string {
	if len(raw) == 0 {
		return "opencode: erro"
	}
	var e struct {
		Name string `json:"name"`
		Data struct {
			Message string `json:"message"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &e); err == nil && e.Data.Message != "" {
		return truncN(e.Data.Message, maxChunk)
	}
	return truncN(string(raw), maxChunk)
}

func trunc(s string) string { return truncN(s, maxChunk) }
func truncN(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
