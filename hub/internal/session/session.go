// Package session define o modelo de uma sessão de agente e seus estados,
// conforme a máquina de estados do doc 03 (modelo de estado).
package session

import (
	"strings"
	"time"
)

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
	// Model é o modelo escolhido no launch, persistido para o resume reusar. Sem
	// ele, agentes que exigem -m em toda invocação (OpenCode) cairiam no default
	// ao continuar a conversa, ignorando a escolha da usuária (SEC-109).
	Model string `json:"model,omitempty"`
	// External = sessão que NÃO foi lançada pelo hub (veio de hook do Claude ou
	// de adoção/tmux). O hub não controla o gate de permissão dela (a resposta é
	// no terminal), então o notifier não re-cutuca nem cutuca "concluído" a cada
	// turno — só avisa uma vez que precisa de você.
	External bool `json:"external,omitempty"`
	// Pane é o alvo composto do tmux ("<socket>\t<pane>") quando a sessão roda
	// dentro do tmux (reportado pelo hook via $TMUX/$TMUX_PANE). Vazio = sessão
	// local fora do tmux. Permite ao app abrir o terminal ao vivo dessa exata
	// sessão (correlação robusta, mesmo com várias sessões na mesma pasta).
	Pane string `json:"pane,omitempty"`
	// PendingQuestions é preenchido quando o pending é uma pergunta de seleção
	// (a ferramenta nativa AskUserQuestion do Claude Code) em vez de um pedido
	// comum de permissão: o app troca o sim/não por um seletor (single/multi
	// select) com as opções em texto. Vazio nos demais casos de needs_you (o
	// app cai de volta no sim/não de PendingPrompt). O Engine é quem preenche
	// (único escritor do Registry) — ver docs/02 e o protocolo do
	// control_request can_use_tool.
	PendingQuestions []Question `json:"pending_questions,omitempty"`
}

// Question é uma pergunta de seleção do AskUserQuestion, no formato que o app
// renderiza: o texto da pergunta, um header curto (categoria/título), se aceita
// múltiplas escolhas (multiSelect) e as opções disponíveis.
type Question struct {
	Question    string           `json:"question"`
	Header      string           `json:"header,omitempty"`
	MultiSelect bool             `json:"multiSelect"`
	Options     []QuestionOption `json:"options"`
}

// QuestionOption é uma opção de resposta de uma Question: o rótulo (o texto que
// vira a resposta, ecoado ao CLI) e uma descrição opcional.
type QuestionOption struct {
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
}

// QuestionAnswer é a resposta da usuária a UMA pergunta pendente: Question é o
// texto EXATO da pergunta (chave do map `answers` do control_response) e
// Selected são os rótulos escolhidos — 1 item em seleção única, N em múltipla.
// Usado pela ação Launcher.Answer (POST /sessions/{id}/answer).
type QuestionAnswer struct {
	Question string   `json:"question"`
	Selected []string `json:"selected"`
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
	// Agent qual agente gerou a sessão ("claude-code"|"codex") — o Launcher o
	// preenche ao mesclar a descoberta dos vários agentes da máquina, para a
	// adoção usar o alvo (e o transcript) certo. Vazio = claude-code (legado).
	Agent string `json:"agent,omitempty"`
	// State só é preenchido para panes vivos do tmux (TmuxList): "running"|
	// "waiting"|"idle", lido do próprio terminal. Vazio para descobertas de disco.
	State string `json:"state,omitempty"`
}

// IsEphemeralCwd diz se um cwd é um diretório INTERNO de app / cache / probe —
// nunca um projeto real do usuário. Sessões de hook nesses caminhos são
// health-checks automáticos (ex.: o CodexBar spawna `claude` em
// ~/Library/Application Support/CodexBar/ClaudeProbe repetidamente), que
// inundariam o app com "mil sessões" sem sentido. O hub as ignora (não registra,
// não cutuca, não recarrega do disco). Comparação case-insensitive.
func IsEphemeralCwd(cwd string) bool {
	lc := strings.ToLower(cwd)
	for _, p := range []string{
		"/library/application support/",
		"/library/caches/",
		"/claudeprobe",
	} {
		if strings.Contains(lc, p) {
			return true
		}
	}
	return false
}

// DirEntry é uma subpasta de um diretório na máquina (seletor de pastas do app).
type DirEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// DirListing é o conteúdo navegável de um diretório: o caminho atual, o pai
// (para "subir um nível") e as subpastas. Alimenta o seletor de pastas ao criar
// uma sessão nova, para a usuária navegar as pastas do Mac em vez de digitar o cwd.
type DirListing struct {
	Path   string     `json:"path"`
	Parent string     `json:"parent"`
	Dirs   []DirEntry `json:"dirs"`
}
