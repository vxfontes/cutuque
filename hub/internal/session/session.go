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
//
// PendingPrompt é o texto do pedido pendente quando a sessão está em needs_you
// (resumo do permission_requested ou a pergunta do needs_input). O app o exibe
// antes de a usuária aprovar — invariante de segurança: nunca aprovar às cegas
// (docs/03). Fica vazio nos demais estados; o Engine o mantém (único escritor).
type Session struct {
	ID            string    `json:"id"`
	Machine       string    `json:"machine"`
	Agent         string    `json:"agent"`
	Title         string    `json:"title"`
	State         State     `json:"state"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
	PendingPrompt string    `json:"pending_prompt,omitempty"`
	// Cwd é a pasta onde o claude roda. Preenchido no launch com pasta e nas
	// sessões descobertas/adotadas do Mac (para o --resume rodar no dir certo).
	Cwd string `json:"cwd,omitempty"`
}

// Discovered é uma sessão do Claude Code encontrada no disco de uma máquina
// (~/.claude/projects/<cwd>/<id>.jsonl) — inclusive as que NÃO foram lançadas
// pelo Cutuque. Permite descobrir e retomar conversas já existentes.
type Discovered struct {
	ID       string `json:"id"`
	Cwd      string `json:"cwd"`
	Title    string `json:"title"`    // 1ª mensagem do usuário
	Last     string `json:"last"`     // última mensagem do usuário (preview)
	Count    int    `json:"count"`    // nº de mensagens do usuário (preview)
	Modified int64  `json:"modified"` // unix epoch (mtime do transcript)
}
