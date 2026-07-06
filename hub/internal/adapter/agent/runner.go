package agent

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/event"
)

// maxTitle é o tamanho do título da sessão (prompt truncado).
const maxTitle = 60

// Applier consome eventos normalizados. O State Engine o satisfaz; o Launcher
// o decora para interceptar pedidos de permissão antes de delegar ao Engine —
// o Runner não conhece nenhum dos dois concretamente (só a interface), e o
// Engine segue o único escritor do Registry.
type Applier interface {
	Apply(event.Event)
}

// Meta são os metadados de criação da sessão que o Runner injeta no evento
// session_started (o Engine cria a sessão com eles).
type Meta struct {
	Machine string // máquina-alvo (nome do Target)
	Prompt  string // prompt inicial, para derivar o Title
	Cwd     string // pasta onde o agente roda (persistida na sessão p/ o resume)
}

// ParseFunc traduz uma linha do stream de saída de um agente em eventos
// normalizados. Cada adapter fornece a sua (claudecode.ParseLine para o
// stream-json do Claude; codex.ParseLine para o `codex exec --json`).
type ParseFunc func(line []byte) ([]event.Event, error)

// Runner observa UMA sessão de um agente: lê o stream de saída de um Handle,
// converte em eventos (via ParseFunc) e alimenta um Applier. O Handle é aberto e
// fechado por quem lança (o Launcher), que também precisa do stdin para
// aprovar/negar (no Claude). O rótulo do agente (agentName) vai no session_started.
type Runner struct {
	app   Applier
	parse ParseFunc
	agent string
}

// NewRunner cria um Runner que usa parse para traduzir o stream e marca as
// sessões com agentName (ex.: "claude-code", "codex").
func NewRunner(app Applier, parse ParseFunc, agentName string) *Runner {
	return &Runner{app: app, parse: parse, agent: agentName}
}

// Run observa a sessão lendo h.Stdout até o stream terminar. Ao ver
// session_started, injeta os metadados (machine, agent, title). Se o stream
// terminar (EOF) sem um evento terminal (finished/errored), marca a sessão como
// errored — não deixar a usuária esperando por um fim que não veio. Não fecha o
// Handle: isso é responsabilidade de quem o abriu.
func (r *Runner) Run(ctx context.Context, h *Handle, meta Meta) error {
	reader := bufio.NewReader(h.Stdout)
	var sessionID string
	sawTerminal := false

	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			evs, perr := r.parse(line)
			if perr != nil {
				// Linha inválida no meio do stream: registra e segue (robustez).
				slog.Warn("agent: linha ignorada", "agent", r.agent, "err", perr)
			}
			for _, e := range evs {
				switch {
				case e.Type == event.SessionStarted:
					sessionID = e.SessionID
					// Metadados de criação: o Engine cria a sessão com eles.
					e.Machine = meta.Machine
					e.Agent = r.agent
					e.Title = truncate(meta.Prompt, maxTitle)
					// Persiste o cwd para o resume rodar na MESMA pasta (o Codex,
					// one-shot, depende disso — cada turno é um processo novo).
					if e.Cwd == "" {
						e.Cwd = meta.Cwd
					}
				case e.SessionID == "":
					// Um Runner observa UMA sessão; eventos sem session_id
					// pertencem à sessão corrente do stream.
					e.SessionID = sessionID
				}
				r.app.Apply(e)
				if e.Type == event.Finished || e.Type == event.Errored {
					sawTerminal = true
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return err
		}
	}

	// EOF sem finished/errored: a sessão morreu sem conclusão → errored.
	if !sawTerminal && sessionID != "" {
		r.app.Apply(event.Event{SessionID: sessionID, Type: event.Errored, At: time.Now()})
	}
	return nil
}

// truncate corta s em n runas (com reticências) para o título da sessão.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
