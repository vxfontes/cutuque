package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

func TestSessionsHandlerReturnsList(t *testing.T) {
	cfg, reg := testDeps()
	base := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "b", Machine: "macbook", Agent: "codex", Title: "t2", State: session.StateDone, CreatedAt: base.Add(time.Minute), UpdatedAt: base.Add(time.Minute)})
	reg.Add(session.Session{ID: "a", Machine: "macbook", Agent: "claude-code", Title: "t1", State: session.StateRunning, CreatedAt: base, UpdatedAt: base})

	req := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, quero \"application/json\"", ct)
	}

	var body struct {
		Sessions []session.Session `json:"sessions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Sessions) != 2 {
		t.Fatalf("len(sessions) = %d, quero 2", len(body.Sessions))
	}
	// Ordenado por CreatedAt: "a" antes de "b".
	if body.Sessions[0].ID != "a" || body.Sessions[1].ID != "b" {
		t.Errorf("ordem = [%q, %q], quero [a, b]", body.Sessions[0].ID, body.Sessions[1].ID)
	}
}

func TestSessionsHandlerEmptyListIsArray(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	// Sem sessões, "sessions" deve ser [] e não null.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if string(raw["sessions"]) != "[]" {
		t.Errorf("sessions = %s, quero []", raw["sessions"])
	}
}

func TestSessionsRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodGet, "/sessions", nil) // sem token
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
