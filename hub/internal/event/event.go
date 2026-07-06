// Package event define o contrato de eventos normalizados, independente do
// agente (Claude Code, Codex, OpenCode). Os adapters traduzem a saída bruta de
// cada agente nestes eventos; o State Engine os consome (ver docs/02-arquitetura.md).
package event

import (
	"encoding/json"
	"time"
)

// Type é o tipo de um evento normalizado.
type Type string

// Tipos de evento (contrato Adapter → State Engine, doc 02).
const (
	SessionStarted      Type = "session_started"      // sessão iniciada
	OutputChunk         Type = "output_chunk"         // pedaço de saída
	NeedsInput          Type = "needs_input"          // agente pediu input/pergunta
	PermissionRequested Type = "permission_requested" // agente pediu permissão
	UserResponded       Type = "user_responded"       // usuária respondeu/aprovou → volta a running
	Finished            Type = "finished"             // tarefa concluída
	Errored             Type = "errored"              // falha/crash
)

// Kinds de output_chunk: o contrato tipado exposto ao app (REST
// GET /sessions/{id}/output e WS output_chunk). Só fazem sentido quando
// Type == OutputChunk.
const (
	KindUser       = "user"        // eco do texto que a usuária enviou
	KindAssistant  = "assistant"   // texto do agente (limpo)
	KindTool       = "tool"        // chamada de ferramenta (resumo do input)
	KindToolResult = "tool_result" // resultado de ferramenta (truncado)
)

// Event é um evento normalizado emitido por um adapter.
//
// Machine, Agent e Title são metadados de criação da sessão: os adapters os
// preenchem no session_started e o State Engine — único escritor de estado —
// cria a sessão com eles (ver hub/review/log.md, achado #1 da Fase 2). Nos
// demais tipos de evento ficam vazios.
//
// ControlID e Input só aparecem em permission_requested: ControlID é o
// request_id do control_request nativo do Claude Code (o alvo da resposta de
// aprovação/negação) e Input é o input original da ferramenta, que precisa ser
// devolvido intacto como updatedInput ao aprovar (protocolo verificado na CLI
// 2.1.198). O Launcher os guarda para responder pelo stdin; o Engine só usa
// Data (resumo humano) para o estado.
//
// Kind só é usado quando Type == OutputChunk: qualifica o pedaço de saída
// como user/assistant/tool/tool_result (ver constantes Kind* acima) para o
// contrato tipado de output do app. Nos demais tipos de evento fica vazio.
type Event struct {
	SessionID string    `json:"session_id"`
	Type      Type      `json:"type"`
	Kind      string    `json:"kind,omitempty"`
	Data      string    `json:"data"`
	At        time.Time `json:"at"`
	Machine   string    `json:"machine,omitempty"`
	Agent     string    `json:"agent,omitempty"`
	Title     string    `json:"title,omitempty"`
	Cwd       string    `json:"cwd,omitempty"`
	Model     string    `json:"model,omitempty"` // modelo escolhido no launch (persistido p/ o resume)
	Pane      string    `json:"pane,omitempty"`
	// External marca eventos vindos de HOOK (sessão não lançada pelo hub). O
	// Runner emite eventos com External=false (autoritativo) — usado por
	// ensureRunning para reassumir sessões pré-criadas por hook numa corrida.
	External  bool            `json:"external,omitempty"`
	ControlID string          `json:"control_id,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
}
