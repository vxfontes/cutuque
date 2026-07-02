// Package event define o contrato de eventos normalizados, independente do
// agente (Claude Code, Codex, OpenCode). Os adapters traduzem a saída bruta de
// cada agente nestes eventos; o State Engine os consome (ver docs/02-arquitetura.md).
package event

import "time"

// Type é o tipo de um evento normalizado.
type Type string

// Tipos de evento (contrato Adapter → State Engine, doc 02).
const (
	SessionStarted      Type = "session_started"      // sessão iniciada
	OutputChunk         Type = "output_chunk"         // pedaço de saída
	NeedsInput          Type = "needs_input"          // agente pediu input/pergunta
	PermissionRequested Type = "permission_requested" // agente pediu permissão
	Finished            Type = "finished"             // tarefa concluída
	Errored             Type = "errored"              // falha/crash
)

// Event é um evento normalizado emitido por um adapter.
type Event struct {
	SessionID string    `json:"session_id"`
	Type      Type      `json:"type"`
	Data      string    `json:"data"`
	At        time.Time `json:"at"`
}
