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

// maxSummary é o tamanho máximo do resumo de inputs de ferramenta (kind
// "tool" e o resumo humano de permission_requested), para o output ao vivo
// ficar legível.
const maxSummary = 120

// maxToolResultChars é o tamanho máximo do texto de um tool_result (kind
// "tool_result") exposto no output ao vivo — contrato: "primeiros ~200 chars".
const maxToolResultChars = 200

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
//
// ToolUseID e RequiresUserInteraction foram confirmados com o AskUserQuestion
// (a ferramenta de seleção única/múltipla do Claude Code): o CLI sempre manda
// tool_use_id (mesmo em ferramentas comuns, ex. Bash) e marca
// requires_user_interaction=true nas que exigem resposta explícita da usuária.
// O hub não distingue por RequiresUserInteraction (não é confiável para todas
// as ferramentas) — usa ToolName=="AskUserQuestion" para identificar a seleção.
type controlRequest struct {
	Subtype                 string          `json:"subtype"`
	ToolName                string          `json:"tool_name"`
	Input                   json.RawMessage `json:"input"`
	Description             string          `json:"description"`
	ToolUseID               string          `json:"tool_use_id"`
	RequiresUserInteraction bool            `json:"requires_user_interaction"`
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
// permission_requested. Guarda o request_id (ControlID), o tool_name/tool_use_id
// (ToolName/ToolUseID) e o input original (Input) que o Launcher devolve ao
// aprovar; Data é um resumo humano para o app. Outros subtypes de
// control_request são ignorados.
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
		ToolName:  l.Request.ToolName,
		ToolUseID: l.Request.ToolUseID,
		At:        at,
	}}
}

// askUserQuestionInput espelha o schema de input.questions do AskUserQuestion
// (protocolo verificado na CLI 2.1.198/2.1.206): só o necessário para o resumo
// humano — o parse completo (para o app renderizar o seletor) é feito pelo
// Engine a partir do Input bruto.
type askUserQuestionInput struct {
	Questions []struct {
		Question string `json:"question"`
	} `json:"questions"`
}

// permissionSummary monta o resumo humano do pedido a partir do tool_name e do
// input.command (quando houver) ou da description. Ex.:
// "Bash: touch x.txt — Create empty probe file".
//
// AskUserQuestion é um caso especial: não é um pedido de permissão de
// ferramenta, é uma pergunta de seleção — o resumo vira "Pergunta: <1ª
// question>" (o app troca o sim/não por um seletor via PendingQuestions;
// Data aqui é só o fallback textual/notificação).
func permissionSummary(req *controlRequest) string {
	if req.ToolName == "AskUserQuestion" {
		if q := firstQuestion(req.Input); q != "" {
			return "Pergunta: " + truncate(q, maxSummary)
		}
		return "Pergunta"
	}
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

// firstQuestion extrai o texto da 1ª pergunta de um input do AskUserQuestion,
// para o resumo humano de permissionSummary. String vazia se não houver.
func firstQuestion(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var in askUserQuestionInput
	if err := json.Unmarshal(raw, &in); err != nil || len(in.Questions) == 0 {
		return ""
	}
	return in.Questions[0].Question
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

// assistantEvents extrai output_chunks de uma mensagem do assistente: texto
// vira kind "assistant" (o texto limpo, sem prefixo); tool_use vira kind
// "tool" (Data = "Nome: resumo do input"); thinking é ignorado.
func assistantEvents(l streamLine, at time.Time) []event.Event {
	blocks := decodeBlocks(l.Message)
	var out []event.Event
	for _, b := range blocks {
		switch b.Type {
		case "text":
			if b.Text != "" {
				out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Kind: event.KindAssistant, Data: b.Text, At: at})
			}
		case "tool_use":
			out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Kind: event.KindTool, Data: toolSummary(b.Name, b.Input), At: at})
		}
		// thinking (e outros) ignorados.
	}
	return out
}

// toolSummary monta o resumo humano de uma chamada de ferramenta: "Nome:
// resumo do input" (ex.: "Bash: touch x.txt"). Sem prefixos decorativos — o
// kind "tool" já identifica o tipo no contrato tipado de output.
func toolSummary(name string, input json.RawMessage) string {
	if name == "" {
		name = "ferramenta"
	}
	detail := toolInputSummary(input)
	if detail == "" {
		return name
	}
	return name + ": " + detail
}

// toolInputSummary resume o input de uma ferramenta: usa input.command quando
// houver (Bash e afins); senão cai no JSON compacto do input inteiro.
func toolInputSummary(input json.RawMessage) string {
	if cmd := commandField(input); cmd != "" {
		return truncate(cmd, maxSummary)
	}
	return truncate(compact(input), maxSummary)
}

// userEvents extrai output_chunks de tool_result: kind "tool_result", Data
// truncado aos primeiros ~200 chars. Sem prefixo — o kind já identifica.
func userEvents(l streamLine, at time.Time) []event.Event {
	blocks := decodeBlocks(l.Message)
	var out []event.Event
	for _, b := range blocks {
		if b.Type != "tool_result" {
			continue
		}
		data := truncate(toolResultText(b.Content), maxToolResultChars)
		out = append(out, event.Event{SessionID: l.SessionID, Type: event.OutputChunk, Kind: event.KindToolResult, Data: data, At: at})
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
