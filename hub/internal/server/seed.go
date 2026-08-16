package server

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/board"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// seedInterval é o intervalo entre transições do simulador de dados fake.
const seedInterval = 5 * time.Second

// Os títulos daqui pra baixo estão em inglês de propósito: quem lê esses dados é
// o revisor da App Store na caixa pública, não a gente. O que o hub gera sozinho
// (rótulo de coluna, "criou o card") continua em pt-BR — traduzir isso mexeria no
// board de verdade.

// seedSessions monta as 4 sessões fake, combinando as máquinas macbook/
// desktop-win com os agentes claude-code/codex.
func seedSessions(now time.Time) []session.Session {
	specs := []struct {
		id, machine, agent, title, cwd string
		state                          session.State
	}{
		{"seed-1", "macbook", "claude-code", "refactor the auth module", "/Users/example/Desktop/coding/acme/.maestri/roles/8c8575fc-1d68-4753-b6fc-5b39ad82c392", session.StateRunning},
		{"seed-2", "desktop-win", "codex", "run the full test suite", "/Users/example/Desktop/coding/acme/acme-api", session.StateNeedsYou},
		{"seed-3", "macbook", "codex", "generate the database migration", "/repo/acme-mobile/3c30c8cd-49d8-449e-9bf8-2baba351ff55", session.StateDone},
		{"seed-4", "desktop-win", "claude-code", "investigate the flaky checkout test", "/Users/example/Desktop/coding/acme/acme-web", session.StateIdle},
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

// seedComment é um comentário de um card de demonstração.
type seedComment struct{ author, text string }

// seedCard descreve um card do quadro de demonstração. `path` é o caminho de
// colunas que o card percorre depois de criado — percorrer em vez de saltar
// direto pro destino é o que faz o hub derivar started_at/reviewed_at/ended_at e
// escrever a linha do tempo (ver board.MemStore.Update).
type seedCard struct {
	title, desc, session, agent, role string
	path                              []string
	comments                          []seedComment
}

// seedGroup é o "ambiente" fake dos cards — o eixo pelo qual o board se organiza.
const seedGroup = "acme"

// seedCards são os 7 cards da caixa pública, espalhados pelas 5 colunas. Os
// quatro primeiros repetem os títulos das sessões fake de propósito: o revisor vê
// o mesmo trabalho na aba de sessões e no quadro, que é como o app funciona de
// verdade.
var seedCards = []seedCard{
	{
		title: "Refactor the auth module", session: "acme-api", agent: "claude-code", role: "marcus",
		desc: "Token renewal happens inside the request handler, so a slow identity provider blocks the response. Move it to a background refresh and have the handler read the cached token.",
		path: []string{"em_progresso"},
		comments: []seedComment{
			{"marcus", "Renewal is out of the handler. Locally p95 on /login went from 840ms to 90ms. Still need to decide what happens when the refresh itself fails."},
		},
	},
	{
		title: "Run the full test suite", session: "acme-api", agent: "codex", role: "tyler",
		desc: "Full run before cutting the release, including the integration tests that need the test database.",
		path: []string{"em_progresso"},
		comments: []seedComment{
			{"tyler", "Paused: the migration step wants approval before it touches the test database. Answer it in the app and I pick up from there."},
		},
	},
	{
		title: "Generate the database migration", session: "acme-api", agent: "codex", role: "brad",
		desc: "Add sessions.revoked_at and backfill it for rows created before the change.",
		path: []string{"em_progresso", "feito"},
		comments: []seedComment{
			{"brad", "Written and applied on a scratch database. Backfill takes about 4s for 120k rows. Ready for review."},
		},
	},
	{
		title: "Investigate the flaky checkout test", session: "acme-web", agent: "claude-code", role: "lauren",
		desc: "Fails roughly one run in twenty, always on CI, never locally. First suspect is the fixed timeout on the payment mock.",
	},
	{
		title: "Rate limit the public API", session: "acme-api", agent: "claude-code", role: "marcus",
		desc: "60 requests per minute per token, 429 with Retry-After above that. Needs a decision on whether the limit is per token or per account.",
	},
	{
		title: "Cache the dashboard queries", session: "acme-web", agent: "codex", role: "camila",
		desc: "The dashboard runs the same four aggregates on every load. Cache them and invalidate on write.",
		path: []string{"em_progresso", "feito", "em_revisao"},
		comments: []seedComment{
			{"camila", "Cache is in, invalidating on write instead of waiting for the TTL."},
			{"ludmilla", "Reviewing. One question: two writes landing in the same second — does the second one still invalidate?"},
		},
	},
	{
		title: "Ship release 2.7.4", session: "acme-mobile", agent: "claude-code", role: "rafael",
		desc: "Cut the tag, build the three targets and upload the build.",
		path: []string{"em_progresso", "feito", "em_revisao", "concluido"},
		comments: []seedComment{
			{"rafael", "Build 24 uploaded on all three targets. Nothing pending here."},
		},
	},
}

// seedBoard popula o quadro com os cards de demonstração e devolve o que ficou lá.
//
// Só semeia quadro VAZIO, por dois motivos: Add gera id novo a cada chamada, então
// um /dev/seed disparado duas vezes duplicaria tudo; e num hub de dev com quadro de
// verdade os cards de mentira entrariam no meio do trabalho real. Quadro que já tem
// card volta intacto.
func seedBoard(st board.Store) []board.Task {
	if st == nil {
		return nil
	}
	if existing := st.List(); len(existing) > 0 {
		return existing
	}
	out := make([]board.Task, 0, len(seedCards))
	for _, c := range seedCards {
		t := st.Add(board.NewTask{
			Title:       c.title,
			Group:       seedGroup,
			Session:     c.session,
			Type:        c.agent,
			Role:        c.role,
			Description: c.desc,
		})
		for _, col := range c.path {
			if moved, ok := st.Update(t.ID, &col, nil, nil, nil, c.role); ok {
				t = moved
			}
		}
		for _, cm := range c.comments {
			if commented, ok := st.AddComment(t.ID, cm.author, cm.text); ok {
				t = commented
			}
		}
		out = append(out, t)
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

// seedResponse é o que o /dev/seed devolve: as sessões fake e os cards do quadro.
type seedResponse struct {
	Sessions []session.Session `json:"sessions"`
	Tasks    []board.Task      `json:"tasks,omitempty"`
}

// SeedHandler (dev-only) popula o registry com sessões fake e o quadro com os
// cards de demonstração e, na primeira chamada, inicia o simulador que move uma
// sessão a cada seedInterval. Em prod responde 404.
//
// É por aqui que a caixa pública ganha conteúdo: `CUTUQUE_PUBLIC` tira a escrita
// do /board justamente pra internet não escrever nele, e a rota não sabe
// distinguir a gente do resto do mundo. Esta aqui sabe — pede token E só existe
// com CUTUQUE_ENV=dev. `st` pode ser nil (hub sem quadro): aí só semeia sessão.
func SeedHandler(cfg config.Config, reg *registry.Registry, st board.Store) http.HandlerFunc {
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

		tasks := seedBoard(st)

		// Inicia o simulador uma única vez, para a vida do processo.
		once.Do(func() {
			d := newSeedDriver(reg, ids)
			go d.run(seedInterval, nil)
		})

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(seedResponse{Sessions: sessions, Tasks: tasks})
	}
}
