package codex

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/event"
)

// collectApplier junta os eventos que o Runner emite (fake do State Engine).
type collectApplier struct{ evs []event.Event }

func (c *collectApplier) Apply(e event.Event) { c.evs = append(c.evs, e) }

// TestLiveCodexSmoke roda o `codex` REAL de ponta a ponta (LocalTarget → Runner)
// e confere que sai o session_started + uma mensagem do agente + finished.
// Custa tokens/API e ~15s, então só roda com CUTUQUE_CODEX_SMOKE=1.
func TestLiveCodexSmoke(t *testing.T) {
	if os.Getenv("CUTUQUE_CODEX_SMOKE") != "1" {
		t.Skip("defina CUTUQUE_CODEX_SMOKE=1 para rodar o smoke contra o codex real")
	}
	dir := t.TempDir()
	tgt := NewLocalTarget("local")

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// Modelo vazio → default da conta (gpt-5-codex não existe em conta ChatGPT).
	// sandbox read-only: o smoke não deve escrever nada.
	h, err := tgt.Start(ctx, "", dir, "", "low", "read-only", "responda com a palavra pronto e nada mais")
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer h.Close()

	app := &collectApplier{}
	if err := tgt.NewRunner(app).Run(ctx, h, agent.Meta{Machine: "local", Prompt: "smoke"}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	var started, assistant, finished bool
	for _, e := range app.evs {
		switch {
		case e.Type == event.SessionStarted && e.SessionID != "":
			started = true
		case e.Type == event.OutputChunk && e.Kind == event.KindAssistant:
			assistant = true
		case e.Type == event.Finished:
			finished = true
		}
	}
	if !started || !assistant || !finished {
		t.Fatalf("eventos incompletos: started=%v assistant=%v finished=%v (%d eventos)", started, assistant, finished, len(app.evs))
	}
}
