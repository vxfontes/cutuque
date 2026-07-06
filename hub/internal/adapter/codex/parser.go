// Package codex adapta o Codex CLI (OpenAI) ao contrato de agente do Cutuque,
// reusando a plataforma de execução do pacote agent (Handle, Runner, Target).
//
// O Codex roda em modo one-shot: `codex exec --json [resume <id>] "<prompt>"`
// transmite eventos JSONL no stdout e SAI ao fim do turno. Cada reply é um novo
// `exec resume` (não há stdin bidirecional como no Claude). O parser aqui traduz
// esse stream de eventos v2 nos event.Event normalizados.
package codex

import (
	"encoding/json"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// maxChunk limita o tamanho de um pedaço de output (resultado de comando etc.)
// para uma linha patológica não inchar o registry/UI.
const maxChunk = 4000

// codexEvent é o envelope de um evento do `codex exec --json`. Só os campos que
// usamos; o resto é ignorado.
type codexEvent struct {
	Type     string          `json:"type"`
	ThreadID string          `json:"thread_id"`
	Item     json.RawMessage `json:"item"`
	Error    json.RawMessage `json:"error"`
}

// codexItem é um item de conversa (item.completed). O tipo próprio do item vem
// em "item_type" ou "type" conforme a versão da CLI — lemos os dois.
type codexItem struct {
	ID               string          `json:"id"`
	Type             string          `json:"type"`
	ItemType         string          `json:"item_type"`
	Text             string          `json:"text"`
	Message          string          `json:"message"`
	Command          string          `json:"command"`
	AggregatedOutput string          `json:"aggregated_output"`
	Changes          json.RawMessage `json:"changes"`
	Query            string          `json:"query"`
}

// kind devolve o tipo próprio do item (item_type tem precedência).
func (it codexItem) kind() string {
	if it.ItemType != "" {
		return it.ItemType
	}
	return it.Type
}

// ParseLine traduz uma linha do `codex exec --json` em eventos normalizados.
// Linhas vazias ou não-JSON viram nenhum evento (o Runner só loga e segue).
func ParseLine(line []byte) ([]event.Event, error) {
	trimmed := strings.TrimSpace(string(line))
	if trimmed == "" {
		return nil, nil
	}
	var ev codexEvent
	if err := json.Unmarshal([]byte(trimmed), &ev); err != nil {
		// Não-JSON no stdout (ex.: um aviso solto) — ignora sem quebrar o stream.
		return nil, nil
	}

	switch ev.Type {
	case "thread.started":
		if ev.ThreadID == "" {
			return nil, nil
		}
		return []event.Event{{Type: event.SessionStarted, SessionID: ev.ThreadID}}, nil
	case "item.completed":
		return itemEvents(ev.Item), nil
	case "turn.completed":
		// Fim do turno: o processo one-shot vai sair (EOF). Marca concluído para
		// o Runner não tratar o EOF como erro.
		return []event.Event{{Type: event.Finished}}, nil
	case "turn.failed", "error", "thread.error", "stream.error":
		return []event.Event{{Type: event.Errored, Data: errText(ev.Error)}}, nil
	default:
		// turn.started, item.started, item.updated, token usage… — sem efeito no
		// estado; o texto final chega no item.completed correspondente.
		return nil, nil
	}
}

// itemEvents mapeia um item concluído para chunks de output.
func itemEvents(raw json.RawMessage) []event.Event {
	if len(raw) == 0 {
		return nil
	}
	var it codexItem
	if err := json.Unmarshal(raw, &it); err != nil {
		return nil
	}
	switch it.kind() {
	case "agent_message":
		if txt := firstNonEmpty(it.Text, it.Message); txt != "" {
			return []event.Event{outChunk(event.KindAssistant, txt)}
		}
	case "reasoning", "todo_list", "user_message":
		// Reasoning/todos são ruído no chat; o eco do usuário já é gravado pelo hub.
		return nil
	case "command_execution", "local_shell_call", "function_call":
		return commandEvents(it)
	case "file_change", "patch_apply", "apply_patch":
		return []event.Event{outChunk(event.KindTool, "editou arquivos")}
	case "web_search", "web_search_call":
		return []event.Event{outChunk(event.KindTool, "web_search "+trunc(it.Query))}
	default:
		// Item desconhecido: não some silenciosamente — mostra um resumo curto.
		if txt := firstNonEmpty(it.Text, it.Message, it.Command); txt != "" {
			return []event.Event{outChunk(event.KindTool, it.kind()+": "+trunc(txt))}
		}
	}
	return nil
}

// commandEvents resume um comando executado (a chamada + a saída, se houver).
func commandEvents(it codexItem) []event.Event {
	cmd := firstNonEmpty(it.Command, it.Text)
	if cmd == "" {
		return nil
	}
	out := []event.Event{outChunk(event.KindTool, "$ "+trunc(cmd))}
	if it.AggregatedOutput != "" {
		out = append(out, outChunk(event.KindToolResult, trunc(it.AggregatedOutput)))
	}
	return out
}

func outChunk(kind, data string) event.Event {
	return event.Event{Type: event.OutputChunk, Kind: kind, Data: data}
}

func errText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return "codex: turno falhou"
	}
	var m struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &m); err == nil && m.Message != "" {
		return trunc(m.Message)
	}
	return trunc(string(raw))
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func trunc(s string) string {
	r := []rune(s)
	if len(r) <= maxChunk {
		return s
	}
	return string(r[:maxChunk]) + "…"
}
