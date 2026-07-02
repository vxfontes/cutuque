package server

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

func TestHookNotificationSetsNeedsYou(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"posso rodar rm?"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateNeedsYou {
		t.Errorf("State = %q, quero \"needs_you\"", s.State)
	}
}

func TestHookStopSetsDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Stop"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
}

func TestHookUnknownEventIsNoOp(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"PreToolUse"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateRunning {
		t.Errorf("State = %q, quero \"running\" (evento não mapeado é no-op)", s.State)
	}
}

func TestHookBadRequest(t *testing.T) {
	cfg, reg := testDeps()

	for _, body := range []string{`{isso não é json`, `{"hook_event_name":"Stop"}`} {
		req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		rec := httptest.NewRecorder()

		Router(cfg, reg).ServeHTTP(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

func TestHookRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"s","hook_event_name":"Stop"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	rec := httptest.NewRecorder()

	Router(cfg, reg).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
