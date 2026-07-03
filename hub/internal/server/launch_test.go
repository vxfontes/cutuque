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

	machines   []string
	removeErr  error
	historyErr error
	dirListing session.DirListing
	dirsErr    error

	discovered   []session.Discovered
	discoverErr  error
	liveSessions []session.Discovered
	liveErr      error
	tmuxPanes    []session.Discovered
	tmuxScreen   string
	tmuxErr      error
	adoptSession session.Session
	adoptErr     error

	gotMachine, gotAgent, gotPrompt, gotCwd string
	gotApproveID, gotDenyID                 string
	gotInputID, gotInputText                string
	gotRemoveID                             string
	gotHistoryID                            string
	gotDirsMachine, gotDirsPath             string
	gotDiscoverMachine                      string
	gotAdoptMachine, gotAdoptID             string
	gotAdoptCwd, gotAdoptTitle              string
	gotTmuxTarget, gotTmuxText              string
}

func (f *fakeLauncher) Machines() []string { return f.machines }
func (f *fakeLauncher) Remove(id string) error {
	f.gotRemoveID = id
	return f.removeErr
}
func (f *fakeLauncher) Resolve(id string) error {
	f.gotRemoveID = id
	return f.removeErr
}
func (f *fakeLauncher) ImportHistory(id string) error {
	f.gotHistoryID = id
	return f.historyErr
}
func (f *fakeLauncher) ListDirs(machine, path string) (session.DirListing, error) {
	f.gotDirsMachine, f.gotDirsPath = machine, path
	return f.dirListing, f.dirsErr
}

func (f *fakeLauncher) Discover(machine string) ([]session.Discovered, error) {
	f.gotDiscoverMachine = machine
	return f.discovered, f.discoverErr
}

func (f *fakeLauncher) Live(machine string) ([]session.Discovered, error) {
	return f.liveSessions, f.liveErr
}

func (f *fakeLauncher) TmuxList(machine string) ([]session.Discovered, error) {
	return f.tmuxPanes, f.tmuxErr
}
func (f *fakeLauncher) TmuxCapture(machine, target string) (string, error) {
	f.gotTmuxTarget = target
	return f.tmuxScreen, f.tmuxErr
}
func (f *fakeLauncher) TmuxSend(machine, target, text string) error {
	f.gotTmuxTarget, f.gotTmuxText = target, text
	return f.tmuxErr
}
func (f *fakeLauncher) TmuxResize(machine, target string, cols, rows int) error {
	f.gotTmuxTarget = target
	return f.tmuxErr
}
func (f *fakeLauncher) TmuxKey(machine, target, key string) error {
	f.gotTmuxTarget, f.gotTmuxText = target, key
	return f.tmuxErr
}
func (f *fakeLauncher) TmuxKill(machine, target string) error {
	f.gotTmuxTarget = target
	return f.tmuxErr
}
func (f *fakeLauncher) TmuxKillServer(machine, socket string) error {
	f.gotTmuxTarget = socket
	return f.tmuxErr
}

func (f *fakeLauncher) Adopt(machine, id, cwd, title string) (session.Session, error) {
	f.gotAdoptMachine, f.gotAdoptID, f.gotAdoptCwd, f.gotAdoptTitle = machine, id, cwd, title
	return f.adoptSession, f.adoptErr
}

func (f *fakeLauncher) Launch(_ context.Context, machine, agent, prompt, cwd string) (session.Session, error) {
	f.gotMachine, f.gotAgent, f.gotPrompt, f.gotCwd = machine, agent, prompt, cwd
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

// TestLaunchPropagatesCwd cobre o campo opcional "cwd" de POST /sessions: o
// Launcher recebe exatamente o texto enviado.
func TestLaunchPropagatesCwd(t *testing.T) {
	f := &fakeLauncher{launchSession: session.Session{ID: "new-1"}}

	rec := do(t, f, http.MethodPost, "/sessions", `{"machine":"macbook","agent":"claude-code","prompt":"faça x","cwd":"/tmp/projeto"}`)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, quero 201", rec.Code)
	}
	if f.gotCwd != "/tmp/projeto" {
		t.Errorf("Launch recebeu cwd=%q, quero \"/tmp/projeto\"", f.gotCwd)
	}
}

// TestLaunchOmittedCwdIsEmpty cobre o caso comum: sem "cwd" no corpo, o
// Launcher recebe string vazia (home).
func TestLaunchOmittedCwdIsEmpty(t *testing.T) {
	f := &fakeLauncher{launchSession: session.Session{ID: "new-1"}}

	rec := do(t, f, http.MethodPost, "/sessions", `{"machine":"macbook","agent":"claude-code","prompt":"faça x"}`)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, quero 201", rec.Code)
	}
	if f.gotCwd != "" {
		t.Errorf("Launch recebeu cwd=%q, quero vazio (omitido)", f.gotCwd)
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
		{"too_many_sessions", launcher.ErrTooManySessions, http.StatusTooManyRequests, "too_many_sessions"},
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

func TestTargetsListsMachines(t *testing.T) {
	f := &fakeLauncher{machines: []string{"macbook", "macmini"}}
	rec := do(t, f, http.MethodGet, "/targets", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"macbook"`) || !strings.Contains(rec.Body.String(), `"macmini"`) {
		t.Errorf("corpo sem as máquinas: %s", rec.Body.String())
	}
}

func TestDeleteSessionOK(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodDelete, "/sessions/abc", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotRemoveID != "abc" {
		t.Errorf("Remove chamado com %q, quero \"abc\"", f.gotRemoveID)
	}
}

func TestDeleteSessionNotFound(t *testing.T) {
	f := &fakeLauncher{removeErr: launcher.ErrUnknownSession}
	rec := do(t, f, http.MethodDelete, "/sessions/ghost", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404", rec.Code)
	}
}

func TestDiscoverListsSessions(t *testing.T) {
	f := &fakeLauncher{discovered: []session.Discovered{
		{ID: "sess-1", Cwd: "/Users/example/proj", Title: "arruma o build", Modified: 1720000000},
	}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/sessions", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotDiscoverMachine != "macbook" {
		t.Errorf("Discover recebeu machine=%q, quero \"macbook\"", f.gotDiscoverMachine)
	}
	var resp struct {
		Sessions []session.Discovered `json:"sessions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("corpo inválido: %v", err)
	}
	if len(resp.Sessions) != 1 || resp.Sessions[0].ID != "sess-1" || resp.Sessions[0].Title != "arruma o build" {
		t.Errorf("sessões = %+v, quero [sess-1]", resp.Sessions)
	}
}

func TestDiscoverUnknownMachine(t *testing.T) {
	f := &fakeLauncher{discoverErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/ghost/sessions", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "unknown_machine")
}

func TestLiveListsSessions(t *testing.T) {
	f := &fakeLauncher{liveSessions: []session.Discovered{
		{ID: "live-1", Cwd: "/x", Title: "rodando agora", Modified: 1720000000},
	}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/live", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	var resp struct {
		Sessions []session.Discovered `json:"sessions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("corpo inválido: %v", err)
	}
	if len(resp.Sessions) != 1 || resp.Sessions[0].ID != "live-1" {
		t.Errorf("sessões = %+v, quero [live-1]", resp.Sessions)
	}
}

func TestDirsListsFolders(t *testing.T) {
	f := &fakeLauncher{dirListing: session.DirListing{
		Path:   "/Users/example",
		Parent: "/Users",
		Dirs:   []session.DirEntry{{Name: "Desktop", Path: "/Users/example/Desktop"}},
	}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/dirs?path=/Users/example", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotDirsMachine != "macbook" || f.gotDirsPath != "/Users/example" {
		t.Errorf("machine/path repassados errados: %q %q", f.gotDirsMachine, f.gotDirsPath)
	}
	var resp session.DirListing
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("corpo inválido: %v", err)
	}
	if resp.Parent != "/Users" || len(resp.Dirs) != 1 || resp.Dirs[0].Name != "Desktop" {
		t.Errorf("listing = %+v", resp)
	}
}

func TestDirsUnknownMachine(t *testing.T) {
	f := &fakeLauncher{dirsErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/x/dirs", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "unknown_machine")
}

func TestLiveDiscoverFailed(t *testing.T) {
	f := &fakeLauncher{liveErr: launcher.ErrDiscoverFailed}
	rec := do(t, f, http.MethodGet, "/machines/macbook/live", "")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, quero 502", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "discover_failed")
}

func TestTmuxListSessions(t *testing.T) {
	f := &fakeLauncher{tmuxPanes: []session.Discovered{{ID: "%12", Cwd: "/x", Title: "work · main"}}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/tmux", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"%12"`) {
		t.Errorf("corpo sem o pane: %s", rec.Body.String())
	}
}

func TestTmuxScreenReturnsCapture(t *testing.T) {
	f := &fakeLauncher{tmuxScreen: "$ echo oi\noi\n$"}
	rec := do(t, f, http.MethodGet, "/machines/macbook/tmux/screen?target=%2512", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotTmuxTarget != "%12" {
		t.Errorf("target recebido = %q, quero \"%%12\"", f.gotTmuxTarget)
	}
	var resp struct {
		Screen string `json:"screen"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil || !strings.Contains(resp.Screen, "oi") {
		t.Errorf("screen inesperado: %q (err %v)", resp.Screen, err)
	}
}

func TestTmuxScreenRequiresTarget(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodGet, "/machines/macbook/tmux/screen", "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, quero 400 sem target", rec.Code)
	}
}

func TestTmuxKeysSends(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/keys", `{"target":"%12","text":"rode os testes"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotTmuxTarget != "%12" || f.gotTmuxText != "rode os testes" {
		t.Errorf("TmuxSend recebeu target=%q text=%q", f.gotTmuxTarget, f.gotTmuxText)
	}
}

func TestTmuxKeysBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	for _, body := range []string{`{bad`, `{"target":"%12"}`, `{"text":"oi"}`} {
		rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/keys", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => %d, quero 400", body, rec.Code)
		}
	}
}

func TestTmuxKillPane(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/kill", `{"target":"/tmp/tmux-501/main\t%0"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotTmuxTarget != "/tmp/tmux-501/main\t%0" {
		t.Errorf("TmuxKill recebeu target=%q", f.gotTmuxTarget)
	}
}

func TestTmuxKillBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/kill", `{"target":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("target vazio => %d, quero 400", rec.Code)
	}
}

func TestTmuxKillServer(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/kill-server", `{"socket":"/tmp/tmux-501/main"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotTmuxTarget != "/tmp/tmux-501/main" {
		t.Errorf("TmuxKillServer recebeu socket=%q", f.gotTmuxTarget)
	}
	rec = do(t, f, http.MethodPost, "/machines/macbook/tmux/kill-server", `{"socket":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("socket vazio => %d, quero 400", rec.Code)
	}
}

func TestAdoptCreated(t *testing.T) {
	f := &fakeLauncher{adoptSession: session.Session{ID: "sess-1", Machine: "macbook", Cwd: "/Users/example/proj", Title: "arruma o build", State: session.StateIdle}}
	rec := do(t, f, http.MethodPost, "/machines/macbook/adopt", `{"id":"sess-1","cwd":"/Users/example/proj","title":"arruma o build"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, quero 201 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotAdoptMachine != "macbook" || f.gotAdoptID != "sess-1" || f.gotAdoptCwd != "/Users/example/proj" || f.gotAdoptTitle != "arruma o build" {
		t.Errorf("Adopt recebeu machine=%q id=%q cwd=%q title=%q", f.gotAdoptMachine, f.gotAdoptID, f.gotAdoptCwd, f.gotAdoptTitle)
	}
	var resp launchResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("corpo inválido: %v", err)
	}
	if resp.Session.ID != "sess-1" {
		t.Errorf("session.id = %q, quero \"sess-1\"", resp.Session.ID)
	}
}

func TestAdoptBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	for _, body := range []string{`{não é json`, `{"cwd":"/x"}`, `{"id":""}`} {
		rec := do(t, f, http.MethodPost, "/machines/macbook/adopt", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

func TestAdoptUnknownMachine(t *testing.T) {
	f := &fakeLauncher{adoptErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodPost, "/machines/ghost/adopt", `{"id":"sess-1"}`)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "unknown_machine")
}

// TestAdoptInvalidSessionID: id fora do formato esperado (SEC-101) → 400.
func TestAdoptInvalidSessionID(t *testing.T) {
	f := &fakeLauncher{adoptErr: launcher.ErrInvalidSessionID}
	rec := do(t, f, http.MethodPost, "/machines/macbook/adopt", `{"id":"x; rm -rf ~"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, quero 400", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "invalid_session_id")
}

// TestDiscoverFailedReturns502: máquina existe mas a descoberta falhou (ssh/
// python/timeout) → 502, distinto de 404 unknown_machine.
func TestDiscoverFailedReturns502(t *testing.T) {
	f := &fakeLauncher{discoverErr: launcher.ErrDiscoverFailed}
	rec := do(t, f, http.MethodGet, "/machines/macbook/sessions", "")
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, quero 502", rec.Code)
	}
	assertErrorCode(t, rec.Body.Bytes(), "discover_failed")
}
