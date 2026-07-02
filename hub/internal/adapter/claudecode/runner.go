package claudecode

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
)

// maxTitle é o tamanho do título da sessão (prompt truncado).
const maxTitle = 60

// Runner observa uma sessão do Claude Code: lê o stream-json do Target, converte
// em eventos e alimenta o State Engine — único escritor do Registry (a criação
// da sessão viaja como metadados no evento session_started).
type Runner struct {
	eng *engine.Engine
}

// NewRunner cria um Runner sobre o engine dado.
func NewRunner(eng *engine.Engine) *Runner {
	return &Runner{eng: eng}
}

// Run lança/observa a sessão até o stream terminar. Ao ver session_started,
// registra a sessão com os metadados do alvo (machine, agent, title). Se o
// stream terminar (EOF) sem um evento terminal (finished/errored), marca a
// sessão como errored — não deixar o usuário esperando por um fim que não veio.
func (r *Runner) Run(ctx context.Context, target Target, prompt string) error {
	rc, err := target.Start(ctx, prompt)
	if err != nil {
		return err
	}
	defer rc.Close()

	reader := bufio.NewReader(rc)
	var sessionID string
	sawTerminal := false

	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			evs, perr := ParseLine(line)
			if perr != nil {
				// Linha inválida no meio do stream: registra e segue (robustez).
				slog.Warn("claudecode: linha ignorada", "err", perr)
			}
			for _, e := range evs {
				switch {
				case e.Type == event.SessionStarted:
					sessionID = e.SessionID
					// Metadados de criação: o Engine cria a sessão com eles.
					e.Machine = target.Name()
					e.Agent = "claude-code"
					e.Title = truncate(prompt, maxTitle)
				case e.SessionID == "":
					// Um Runner observa UMA sessão; eventos sem session_id
					// pertencem à sessão corrente do stream.
					e.SessionID = sessionID
				}
				r.eng.Apply(e)
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
		r.eng.Apply(event.Event{SessionID: sessionID, Type: event.Errored, At: time.Now()})
	}
	return nil
}
