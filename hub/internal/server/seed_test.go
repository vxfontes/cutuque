package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

func TestPlausibleNext(t *testing.T) {
	cases := []struct {
		from session.State
		tick int
		want session.State
	}{
		{session.StateIdle, 0, session.StateRunning},
		{session.StateRunning, 0, session.StateNeedsYou},
		{session.StateRunning, 1, session.StateDone},
		{session.StateRunning, 2, session.StateError},
		{session.StateRunning, 3, session.StateNeedsYou}, // cicla
		{session.StateNeedsYou, 0, session.StateRunning},
		{session.StateDone, 0, session.StateRunning},
		{session.StateError, 0, session.StateRunning},
	}
	for _, c := range cases {
		if got := plausibleNext(c.from, c.tick); got != c.want {
			t.Errorf("plausibleNext(%q, %d) = %q, quero %q", c.from, c.tick, got, c.want)
		}
	}
}

func TestSeedDriverStepAdvancesOneSession(t *testing.T) {
	reg := registry.New()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "seed-1", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	reg.Add(session.Session{ID: "seed-2", State: session.StateRunning, CreatedAt: now.Add(time.Minute), UpdatedAt: now})

	d := newSeedDriver(reg, []string{"seed-1", "seed-2"})
	d.step() // avança seed-1 com tick 0: running -> needs_you

	got, _ := reg.Get("seed-1")
	if got.State != session.StateNeedsYou {
		t.Errorf("seed-1 State = %q, quero \"needs_you\"", got.State)
	}
	// seed-2 ainda não foi tocada.
	if s, _ := reg.Get("seed-2"); s.State != session.StateRunning {
		t.Errorf("seed-2 State = %q, quero \"running\" (round-robin)", s.State)
	}

	d.step() // avança seed-2 com tick 1: running -> done
	if s, _ := reg.Get("seed-2"); s.State != session.StateDone {
		t.Errorf("seed-2 State = %q, quero \"done\"", s.State)
	}
}

func TestSeedHandlerDevReturnsFourSessions(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var body struct {
		Sessions []session.Session `json:"sessions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Sessions) != 4 {
		t.Fatalf("len(sessions) = %d, quero 4", len(body.Sessions))
	}

	machines := map[string]bool{}
	agents := map[string]bool{}
	for _, s := range body.Sessions {
		machines[s.Machine] = true
		agents[s.Agent] = true
	}
	for _, m := range []string{"macbook", "desktop-win"} {
		if !machines[m] {
			t.Errorf("máquina %q ausente no seed", m)
		}
	}
	for _, a := range []string{"claude-code", "codex"} {
		if !agents[a] {
			t.Errorf("agente %q ausente no seed", a)
		}
	}

	// As sessões devem ter sido registradas no registry.
	if len(reg.List()) != 4 {
		t.Errorf("registry tem %d sessões, quero 4", len(reg.List()))
	}
}

func TestSeedHandlerProdReturns404(t *testing.T) {
	cfg, reg := testDeps()
	cfg.Env = "prod"

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret") // auth ok; deve cair no 404
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404 (seed é dev-only)", rec.Code)
	}
}

func TestSeedRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil) // sem token
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
