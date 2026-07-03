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

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateNeedsYou {
		t.Errorf("State = %q, quero \"needs_you\"", s.State)
	}
}

// TestHookAutoRegistersUnknownSession: um hook de uma sessão que o hub NÃO
// lançou (interativa/tmux) auto-registra a sessão e a leva a needs_you — a base
// para "qualquer claude no Mac aparece e cutuca".
func TestHookAutoRegistersUnknownSession(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"desconhecida-123","hook_event_name":"Notification","message":"posso rodar?","cwd":"/Users/example/proj","machine":"macbook"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	s, ok := reg.Get("desconhecida-123")
	if !ok {
		t.Fatal("sessão desconhecida não foi auto-registrada pelo hook")
	}
	if s.State != session.StateNeedsYou || s.Machine != "macbook" || s.Cwd != "/Users/example/proj" {
		t.Errorf("sessão auto-registrada errada: %+v", s)
	}
}

// TestHookSessionStartRegistersRunning: SessionStart auto-registra como running.
func TestHookSessionStartRegistersRunning(t *testing.T) {
	cfg, reg := testDeps()
	body := `{"session_id":"nova-1","hook_event_name":"SessionStart","cwd":"/Users/example/x","machine":"macbook"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, ok := reg.Get("nova-1"); !ok || s.State != session.StateRunning {
		t.Errorf("SessionStart devia registrar running; got ok=%v state=%q", ok, s.State)
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

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
}

// TestHookNotificationPermissionBlocks: a mensagem real de permissão do Claude
// ("Claude needs your permission") é bloqueio → needs_you.
func TestHookNotificationPermissionBlocks(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateNeedsYou {
		t.Errorf("permissão devia dar needs_you; State = %q", s.State)
	}
}

// TestHookPermissionMessageLocalized: a mensagem de permissão do Claude é
// traduzida para PT-BR no prompt (preservando o nome da ferramenta).
func TestHookPermissionMessageLocalized(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	s, _ := reg.Get("s")
	if s.PendingPrompt != "Claude precisa da sua permissão para usar Bash" {
		t.Errorf("prompt não traduzido: %q", s.PendingPrompt)
	}
}

// TestHookIdleNotificationBecomesDone: a mensagem ociosa do Claude ("waiting for
// your input") NÃO é bloqueio — vira done, não needs_you.
func TestHookIdleNotificationBecomesDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateRunning, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("espera ociosa devia dar done; State = %q", s.State)
	}
}

// TestHookIdleDoesNotResurrectDone: o bug relatado — uma sessão JÁ concluída
// recebe o Notification ocioso e NÃO deve voltar para needs_you.
func TestHookIdleDoesNotResurrectDone(t *testing.T) {
	cfg, reg := testDeps()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "s", Machine: "macbook", Agent: "claude-code", Title: "t", State: session.StateDone, External: true, CreatedAt: now, UpdatedAt: now})

	body := `{"session_id":"s","hook_event_name":"Notification","message":"Claude is waiting for your input"}`
	req := httptest.NewRequest(http.MethodPost, "/hooks/claude", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if s, _ := reg.Get("s"); s.State != session.StateDone {
		t.Errorf("sessão concluída não pode voltar pra needs_you; State = %q", s.State)
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

	Router(cfg, reg, nil).ServeHTTP(rec, req)

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

		Router(cfg, reg, nil).ServeHTTP(rec, req)

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

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}
