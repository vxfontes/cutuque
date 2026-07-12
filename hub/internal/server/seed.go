package server

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// seedInterval é o intervalo entre transições do simulador de dados fake.
const seedInterval = 5 * time.Second

// seedSessions monta as 4 sessões fake, combinando as máquinas macbook/
// desktop-win com os agentes claude-code/codex.
func seedSessions(now time.Time) []session.Session {
	specs := []struct {
		id, machine, agent, title, cwd string
		state                          session.State
	}{
		{"seed-1", "macbook", "claude-code", "refatorar módulo de auth", "/Users/example/Desktop/coding/acme/.maestri/roles/8c8575fc-1d68-4753-b6fc-5b39ad82c392", session.StateRunning},
		{"seed-2", "desktop-win", "codex", "rodar suíte de testes", "/Users/example/Desktop/coding/personal/cutuque", session.StateNeedsYou},
		{"seed-3", "macbook", "codex", "gerar migração do banco", "/repo/acme-mobile/3c30c8cd-49d8-449e-9bf8-2baba351ff55", session.StateDone},
		{"seed-4", "desktop-win", "claude-code", "investigar flaky test", "/Users/example/Desktop/coding/side-project", session.StateIdle},
	}
	out := make([]session.Session, len(specs))
	for i, s := range specs {
		// Espaça o CreatedAt para a ordenação por criação ficar estável.
		created := now.Add(time.Duration(i) * time.Second)
		out[i] = session.Session{
			ID:        s.id,
			Machine:   s.machine,
			Agent:     s.agent,
			Title:     s.title,
			State:     s.state,
			Cwd:       s.cwd,
			CreatedAt: created,
			UpdatedAt: created,
		}
	}
	return out
}

// plausibleNext devolve um próximo estado plausível para o simulador, seguindo
// as transições do doc 03. Como running tem vários sucessores, o tick escolhe
// entre eles de forma ciclíca para o demo visitar needs_you/done/error.
func plausibleNext(s session.State, tick int) session.State {
	switch s {
	case session.StateRunning:
		switch tick % 3 {
		case 0:
			return session.StateNeedsYou
		case 1:
			return session.StateDone
		default:
			return session.StateError
		}
	default:
		// idle/needs_you/done/error → volta a rodar (novo prompt/retry/resposta).
		return session.StateRunning
	}
}

// seedDriver avança as sessões fake, uma por tick, em round-robin.
type seedDriver struct {
	reg    *registry.Registry
	ids    []string
	cursor int
	tick   int
}

func newSeedDriver(reg *registry.Registry, ids []string) *seedDriver {
	return &seedDriver{reg: reg, ids: ids}
}

// step avança a próxima sessão para um estado plausível.
func (d *seedDriver) step() {
	if len(d.ids) == 0 {
		return
	}
	id := d.ids[d.cursor%len(d.ids)]
	if s, ok := d.reg.Get(id); ok {
		_ = d.reg.UpdateState(id, plausibleNext(s.State, d.tick))
	}
	d.cursor++
	d.tick++
}

// run roda o simulador até stop ser fechado.
func (d *seedDriver) run(interval time.Duration, stop <-chan struct{}) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			d.step()
		}
	}
}

// SeedHandler (dev-only) popula o registry com sessões fake e, na primeira
// chamada, inicia o simulador que move uma sessão a cada seedInterval. Em prod
// responde 404.
func SeedHandler(cfg config.Config, reg *registry.Registry) http.HandlerFunc {
	var once sync.Once
	return func(w http.ResponseWriter, r *http.Request) {
		if cfg.Env != "dev" {
			http.NotFound(w, r)
			return
		}

		sessions := seedSessions(time.Now())
		ids := make([]string, len(sessions))
		for i, s := range sessions {
			reg.Add(s)
			ids[i] = s.ID
		}

		// Inicia o simulador uma única vez, para a vida do processo.
		once.Do(func() {
			d := newSeedDriver(reg, ids)
			go d.run(seedInterval, nil)
		})

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(sessionsResponse{Sessions: sessions})
	}
}
