// Package session define o modelo de uma sessão de agente e seus estados,
// conforme a máquina de estados do doc 03 (modelo de estado).
package session

import "time"

// State é o estado atual de uma sessão de agente.
type State string

// Estados possíveis de uma sessão (ver docs/03-modelo-de-estado.md).
const (
	StateRunning  State = "running"   // agente trabalhando
	StateNeedsYou State = "needs_you" // pediu permissão/input ou travou
	StateDone     State = "done"      // tarefa concluída
	StateError    State = "error"     // crashou / erro
	StateIdle     State = "idle"      // sessão viva, sem tarefa ativa
)

// Session é uma sessão de agente conhecida pelo hub.
// Os timestamps são serializados em RFC3339 (padrão do time.Time em JSON).
type Session struct {
	ID        string    `json:"id"`
	Machine   string    `json:"machine"`
	Agent     string    `json:"agent"`
	Title     string    `json:"title"`
	State     State     `json:"state"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
