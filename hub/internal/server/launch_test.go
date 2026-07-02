package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// fakeLauncher implementa server.Launcher com retornos programáveis e registra
// os argumentos recebidos, para os testes de contrato REST.
type fakeLauncher struct {
	launchSession session.Session
	launchErr     error
	approveErr    error
	denyErr       error
	sendErr       error

	gotMachine, gotAgent, gotPrompt string
	gotApproveID, gotDenyID         string
	gotInputID, gotInputText        string
}

func (f *fakeLauncher) Launch(_ context.Context, machine, agent, prompt string) (session.Session, error) {
	f.gotMachine, f.gotAgent, f.gotPrompt = machine, agent, prompt
	return f.launchSession, f.launchErr
}
func (f *fakeLauncher) Approve(id string) error { f.gotApproveID = id; return f.approveErr }
func (f *fakeLauncher) Deny(id string) error    { f.gotDenyID = id; return f.denyErr }
func (f *fakeLauncher) SendText(id, text string) error {
	f.gotInputID, f.gotInputText = id, text
	return f.sendErr
}

// do envia um POST autenticado e devolve o recorder.
func do(t *testing.T, lch Launcher, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, lch).ServeHTTP(rec, req)
	return rec
}

func TestLaunchCreated(t *testing.T) {
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	f := &fakeLauncher{launchSession: session.Session{ID: "new-1", Machine: "macbook", Agent: "claude-code", Title: "faça x", State: session.StateRunning, CreatedAt: now, UpdatedAt: now}}

	rec := do(t, f, http.MethodPost, "/sessions", `{"machine":"macbook","agent":"claude-code","prompt":"faça x"}`)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, quero 201", rec.Code)
	}
	if f.gotMachine != "macbook" || f.gotAgent != "claude-code" || f.gotPrompt != "faça x" {
		t.Errorf("Launch recebeu machine=%q agent=%q prompt=%q", f.gotMachine, f.gotAgent, f.gotPrompt)
	}
	var resp launchResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("corpo inválido: %v", err)
	}
	if resp.Session.ID != "new-1" {
		t.Errorf("session.id = %q, quero \"new-1\"", resp.Session.ID)
	}
}

func TestLaunchErrorStatuses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"unknown_machine", launcher.ErrUnknownMachine, http.StatusBadRequest, "unknown_machine"},
		{"unknown_agent", launcher.ErrUnknownAgent, http.StatusBadRequest, "unknown_agent"},
		{"launch_timeout", launcher.ErrLaunchTimeout, http.StatusGatewayTimeout, "launch_timeout"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{launchErr: c.err}
			rec := do(t, f, http.MethodPost, "/sessions", `{"machine":"m","agent":"a","prompt":"p"}`)
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, quero %d", rec.Code, c.wantStatus)
			}
			assertErrorCode(t, rec.Body.Bytes(), c.wantCode)
		})
	}
}

func TestLaunchBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	for _, body := range []string{`{não é json`, `{"machine":"m","agent":"a"}`, `{"machine":"","agent":"a","prompt":"p"}`} {
		rec := do(t, f, http.MethodPost, "/sessions", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

func TestApproveStatuses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"ok", nil, http.StatusOK, ""},
		{"unknown", launcher.ErrUnknownSession, http.StatusNotFound, "unknown_session"},
		{"stale", launcher.ErrStaleState, http.StatusConflict, "stale_state"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{approveErr: c.err}
			rec := do(t, f, http.MethodPost, "/sessions/abc/approve", "")
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, quero %d", rec.Code, c.wantStatus)
			}
			if f.gotApproveID != "abc" {
				t.Errorf("Approve recebeu id=%q, quero \"abc\"", f.gotApproveID)
			}
			if c.wantCode != "" {
				assertErrorCode(t, rec.Body.Bytes(), c.wantCode)
			}
		})
	}
}

func TestDenyOK(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/sessions/xyz/deny", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if f.gotDenyID != "xyz" {
		t.Errorf("Deny recebeu id=%q, quero \"xyz\"", f.gotDenyID)
	}
}

func TestInputStatuses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"ok", nil, http.StatusOK, ""},
		{"unknown", launcher.ErrUnknownSession, http.StatusNotFound, "unknown_session"},
		{"no_live", launcher.ErrNoHandle, http.StatusConflict, "no_live_session"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{sendErr: c.err}
			rec := do(t, f, http.MethodPost, "/sessions/s1/input", `{"text":"continue"}`)
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, quero %d", rec.Code, c.wantStatus)
			}
			if f.gotInputID != "s1" || f.gotInputText != "continue" {
				t.Errorf("SendText recebeu id=%q text=%q", f.gotInputID, f.gotInputText)
			}
			if c.wantCode != "" {
				assertErrorCode(t, rec.Body.Bytes(), c.wantCode)
			}
		})
	}
}

func TestInputBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	for _, body := range []string{`{nope`, `{"text":""}`, `{}`} {
		rec := do(t, f, http.MethodPost, "/sessions/s1/input", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

func TestCommandsRequireAuth(t *testing.T) {
	cfg, reg := testDeps()
	f := &fakeLauncher{}
	req := httptest.NewRequest(http.MethodPost, "/sessions", strings.NewReader(`{"machine":"m","agent":"a","prompt":"p"}`))
	rec := httptest.NewRecorder()
	Router(cfg, reg, f).ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401 sem token", rec.Code)
	}
}

func assertErrorCode(t *testing.T, body []byte, want string) {
	t.Helper()
	var e struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &e); err != nil {
		t.Fatalf("corpo de erro inválido: %v (%s)", err, body)
	}
	if e.Error != want {
		t.Errorf("error = %q, quero %q", e.Error, want)
	}
}
