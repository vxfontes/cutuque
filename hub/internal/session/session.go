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
