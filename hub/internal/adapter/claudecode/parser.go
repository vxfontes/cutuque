// Package claudecode é o adapter do Claude Code: traduz a saída stream-json do
// `claude -p --output-format stream-json` em eventos normalizados (pacote
// event), que alimentam o State Engine. Ver docs/02 e docs/03.
package claudecode

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// maxSummary é o tamanho máximo do resumo de inputs de ferramenta e de
// resultados, para o output ao vivo ficar legível.
const maxSummary = 120

// streamLine é uma linha do stream-json do Claude Code. Só os campos usados.
type streamLine struct {
	Type      string          `json:"type"`
	Subtype   string          `json:"subtype"`
	SessionID string          `json:"session_id"`
	IsError   bool            `json:"is_error"`
	Result    string          `json:"result"`
	Message   *streamMessage  `json:"message"`
	RequestID string          `json:"request_id"` // control_request: alvo do control_response
	Request   *controlRequest `json:"request"`    // control_request: detalhes do pedido
}

// controlRequest é o pedido de permissão nativo (can_use_tool): o CLI o emite no
// stdout e aguarda um control_response no stdin (verificado na CLI 2.1.198).
type controlRequest struct {
	Subtype     string          `json:"subtype"`
	ToolName    string          `json:"tool_name"`
	Input       json.RawMessage `json:"input"`
	Description string          `json:"description"`
}

type streamMessage struct {
	Content json.RawMessage `json:"content"`
}

type contentBlock struct {
	Type    string          `json:"type"`
	Text    string          `json:"text"`
	Name    string          `json:"name"`
	Input   json.RawMessage `json:"input"`
	Content json.RawMessage `json:"content"` // usado em tool_result (string ou array)
}

// ParseLine converte uma linha do stream-json em zero ou mais eventos
// normalizados. Linhas de tipos irrelevantes (hook_started, hook_response,
// rate_limit_event, thinking, desconhecidos) produzem zero eventos sem erro.
// Retorna erro apenas quando a linha não é JSON válido.
func ParseLine(line []byte) ([]event.Event, error) {
	var l streamLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, err
	}

	at := time.Now()
	switch l.Type {
	case "system":
		if l.Subtype == "init" {
			return []event.Event{{SessionID: l.SessionID, Type: event.SessionStarted, At: at}}, nil
		}
		return nil, nil // thinking_tokens, hook_started, hook_response, etc.

	case "assistant":
		return assistantEvents(l, at), nil

	case "user":
		return userEvents(l, at), nil

	case "result":
		return resultEvent(l, at), nil

	case "control_request":
		return controlRequestEvent(l, at), nil

	default:
		// rate_limit_event e quaisquer tipos desconhecidos: ignorar.
		return nil, nil
	}
}

// controlRequestEvent traduz um control_request/can_use_tool em um
// permission_requested. Guarda o request_id (ControlID) e o input original
// (Input) que o Launcher devolve ao aprovar; Data é um resumo humano para o
// app. Outros subtypes de control_request são ignorados.
func controlRequestEvent(l streamLine, at time.Time) []event.Event {
	if l.Request == nil || l.Request.Subtype != "can_use_tool" {
		return nil
	}
	return []event.Event{{
		SessionID: l.SessionID, // vazio no stream; o Runner preenche com a sessão corrente
		Type:      event.PermissionRequested,
		Data:      permissionSummary(l.Request),
		ControlID: l.RequestID,
		Input:     l.Request.Input,
		At:        at,
	}}
}

// permissionSummary monta o resumo humano do pedido a partir do tool_name e do
// input.command (quando houver) ou da description. Ex.:
// "Bash: touch x.txt — Create empty probe file".
func permissionSummary(req *controlRequest) string {
	tool := req.ToolName
	if tool == "" {
		tool = "ferramenta"
	}
	var detail string
	if cmd := commandField(req.Input); cmd != "" {
		detail = truncate(cmd, maxSummary)
		if req.Description != "" {
			detail += " — " + req.Description
		}
	} else if req.Description != "" {
		detail = req.Description
	}
	if detail == "" {
		return tool
	}
	return tool + ": " + detail
}

// commandField extrai input.command de um input de ferramenta, se presente.
func commandField(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var in struct {
		Command string `json:"command"`
	}
	_ = json.Unmarshal(raw, &in)
	return in.Command
}

// assistantEvents extrai output_chunks de uma mensagem do assistente: texto vira
// o próprio texto; tool_use vira "→ <name>: <input resumido>"; thinking é ignorado.
func assistantEvents(l streamLine, at time.Time) []event.Event {
	blocks := decodeBlocks(l.Message)
	var out []event.Event
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if b.Text != "" {
				out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Data: b.Text, At: at})
			}
		case "tool_use":
			data := "→ " + b.Name + ": " + truncate(compact(b.Input), maxSummary)
			out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Data: data, At: at})
		}
		// thinking (e outros) ignorados.
	}
	return out
}

// userEvents extrai output_chunks de tool_result: "← <primeiros 120 chars>".
func userEvents(l streamLine, at time.Time) []event.Event {
	blocks := decodeBlocks(l.Message)
	var out []event.Event
	for _, b := range blocks {
		if b.Type != "tool_result" {
			continue
		}
		data := "← " + truncate(toolResultText(b.Content), maxSummary)
		out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Data: data, At: at})
	}
	return out
}

// resultEvent mapeia o result final para finished (sucesso) ou errored (erro).
func resultEvent(l streamLine, at time.Time) []event.Event {
	if l.IsError || l.Subtype != "success" {
		return []event.Event{{SessionID: l.SessionID, Type: event.Errored, Data: l.Result, At: at}}
	}
	return []event.Event{{SessionID: l.SessionID, Type: event.Finished, Data: l.Result, At: at}}
}

// decodeBlocks decodifica message.content como um array de blocos. Se for uma
// string (mensagem de texto simples) ou ausente, devolve vazio.
func decodeBlocks(m *streamMessage) []contentBlock {
	if m == nil || len(m.Content) == 0 {
		return nil
	}
	var blocks []contentBlock
	if err := json.Unmarshal(m.Content, &blocks); err != nil {
		return nil
	}
	return blocks
}

// toolResultText extrai o texto de um content de tool_result, que pode ser uma
// string ou um array de blocos {type:text,text:...}.
func toolResultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var blocks []contentBlock
	if err := json.Unmarshal(raw, &blocks); err == nil {
		var sb strings.Builder
		for _, b := range blocks {
			sb.WriteString(b.Text)
		}
		return sb.String()
	}
	return ""
}

// compact remove espaços supérfluos do JSON de input para o resumo.
func compact(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	return string(raw)
}

// truncate limita s a n runes (não bytes), para não cortar no meio de um rune.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
