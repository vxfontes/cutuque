package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os/exec"
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
	answerErr     error

	interruptErr    error
	interruptEffect launcher.InterruptEffect

	machines     []string
	reachability []launcher.Reachability
	removeErr    error
	resolveErr   error
	historyErr   error
	dirListing   session.DirListing
	dirsErr      error

	fileListing session.FileListing
	fsErr       error
	gitDiff     session.GitDiff
	gitErr      error
	fileContent session.FileContent
	readErr     error
	fileWrite   session.FileWrite
	writeErr    error
	fileBytes   []byte
	downloadErr error
	// downloadClosed é preenchido pelo ReadCloser fake quando Close() roda —
	// prova que o handler SEMPRE fecha o corpo do download (defer), mesmo no
	// caminho feliz. Ver closeTrackingReader.
	downloadClosed bool

	discovered   []session.Discovered
	discoverErr  error
	liveSessions []session.Discovered
	liveErr      error
	tmuxPanes    []session.Discovered
	tmuxScreen   string
	tmuxErr      error
	adoptSession session.Session
	adoptErr     error

	tmuxNewTarget string
	gotTmuxAgent  string

	// Terminal livre: o teste do PTY roda um programa de verdade no lugar do
	// `ssh` (não dá para fingir um pty com um mock).
	shellProg string
	shellArgs []string
	shellErr  error

	gotMachine, gotAgent, gotPrompt, gotCwd string
	gotModel, gotEffort, gotSandbox         string
	gotApproveID, gotDenyID                 string
	gotInputID, gotInputText                string
	gotRemoveID                             string
	gotResolveID                            string
	gotHistoryID                            string
	gotDirsMachine, gotDirsPath             string
	gotFsMachine, gotFsPath                 string
	gotGitMachine, gotGitDir                string
	gotReadMachine, gotReadPath             string
	gotWriteMachine, gotWritePath           string
	gotWriteContent                         []byte
	gotDownloadMachine, gotDownloadPath     string
	gotShellMachine                         string
	gotDiscoverMachine                      string
	gotAdoptMachine, gotAdoptID             string
	gotAdoptCwd, gotAdoptTitle              string
	gotAdoptAgent                           string
	gotTmuxTarget, gotTmuxText              string
	gotAnswerID                             string
	gotAnswers                              []session.QuestionAnswer
	gotInterruptID                          string
}

func (f *fakeLauncher) Machines() []string { return f.machines }
func (f *fakeLauncher) Reachability() []launcher.Reachability {
	return f.reachability
}
func (f *fakeLauncher) Remove(id string) error {
	f.gotRemoveID = id
	return f.removeErr
}
func (f *fakeLauncher) Resolve(id string) error {
	f.gotResolveID = id
	return f.resolveErr
}
func (f *fakeLauncher) ImportHistory(id string) error {
	f.gotHistoryID = id
	return f.historyErr
}
func (f *fakeLauncher) ListDirs(machine, path string) (session.DirListing, error) {
	f.gotDirsMachine, f.gotDirsPath = machine, path
	return f.dirListing, f.dirsErr
}
func (f *fakeLauncher) ListFiles(machine, path string) (session.FileListing, error) {
	f.gotFsMachine, f.gotFsPath = machine, path
	return f.fileListing, f.fsErr
}
func (f *fakeLauncher) GitDiff(machine, dir string) (session.GitDiff, error) {
	f.gotGitMachine, f.gotGitDir = machine, dir
	return f.gitDiff, f.gitErr
}
func (f *fakeLauncher) ReadFile(machine, path string) (session.FileContent, error) {
	f.gotReadMachine, f.gotReadPath = machine, path
	return f.fileContent, f.readErr
}
func (f *fakeLauncher) WriteFile(machine, path string, content []byte) (session.FileWrite, error) {
	f.gotWriteMachine, f.gotWritePath, f.gotWriteContent = machine, path, content
	return f.fileWrite, f.writeErr
}
func (f *fakeLauncher) DownloadFile(ctx context.Context, machine, path string) (io.ReadCloser, error) {
	f.gotDownloadMachine, f.gotDownloadPath = machine, path
	if f.downloadErr != nil {
		return nil, f.downloadErr
	}
	return &closeTrackingReader{Reader: bytes.NewReader(f.fileBytes), closed: &f.downloadClosed}, nil
}

// closeTrackingReader é um io.ReadCloser que registra se Close foi chamado —
// o fake do download real (StdoutPipe) é um processo de verdade, aqui só
// precisamos provar que o handler REST fecha (defer) o que recebe.
type closeTrackingReader struct {
	io.Reader
	closed *bool
}

func (c *closeTrackingReader) Close() error {
	*c.closed = true
	return nil
}

// ShellCommand devolve o comando que o fake mandar rodar (o teste do PTY troca
// o `ssh` por um script), ou o erro programado.
func (f *fakeLauncher) ShellCommand(ctx context.Context, machine string) (*exec.Cmd, error) {
	f.gotShellMachine = machine
	if f.shellErr != nil {
		return nil, f.shellErr
	}
	return exec.CommandContext(ctx, f.shellProg, f.shellArgs...), nil
}

func (f *fakeLauncher) Discover(machine string) ([]session.Discovered, error) {
	f.gotDiscoverMachine = machine
	return f.discovered, f.discoverErr
}

func (f *fakeLauncher) Live(machine, agent string) ([]session.Discovered, error) {
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
func (f *fakeLauncher) TmuxNewSession(machine, group, sess, cwd, agent string) (string, error) {
	f.gotTmuxAgent = agent
	if f.tmuxErr != nil {
		return "", f.tmuxErr
	}
	return f.tmuxNewTarget, nil
}

func (f *fakeLauncher) Adopt(machine, id, cwd, title, agent string) (session.Session, error) {
	f.gotAdoptMachine, f.gotAdoptID, f.gotAdoptCwd, f.gotAdoptTitle = machine, id, cwd, title
	f.gotAdoptAgent = agent
	return f.adoptSession, f.adoptErr
}

func (f *fakeLauncher) Launch(_ context.Context, machine, agent, prompt, cwd, model, effort, sandbox string) (session.Session, error) {
	f.gotMachine, f.gotAgent, f.gotPrompt, f.gotCwd = machine, agent, prompt, cwd
	f.gotModel, f.gotEffort, f.gotSandbox = model, effort, sandbox
	return f.launchSession, f.launchErr
}
func (f *fakeLauncher) Approve(id string) error { f.gotApproveID = id; return f.approveErr }
func (f *fakeLauncher) Deny(id string) error    { f.gotDenyID = id; return f.denyErr }
func (f *fakeLauncher) Answer(id string, answers []session.QuestionAnswer) error {
	f.gotAnswerID, f.gotAnswers = id, answers
	return f.answerErr
}
func (f *fakeLauncher) Interrupt(id string) (launcher.InterruptEffect, error) {
	f.gotInterruptID = id
	return f.interruptEffect, f.interruptErr
}
func (f *fakeLauncher) SendText(id, text string) error {
	f.gotInputID, f.gotInputText = id, text
	return f.sendErr
}
func (f *fakeLauncher) Reply(id, text string) error {
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

func TestGetGitDiffDevolveStatusEDiff(t *testing.T) {
	f := &fakeLauncher{gitDiff: session.GitDiff{
		Dir: "/repo", Root: "/repo", State: "changes",
		Files: []session.GitFileChange{{Path: "main.go", Worktree: "modified"}},
		Diff:  "\x1b[31m-old\n\x1b[32m+new",
	}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/git/diff?dir=%2Frepo", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	if f.gotGitMachine != "macbook" || f.gotGitDir != "/repo" {
		t.Fatalf("machine/dir repassados errados: %q %q", f.gotGitMachine, f.gotGitDir)
	}
	var got session.GitDiff
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("json inválido: %v", err)
	}
	if got.State != "changes" || len(got.Files) != 1 || !strings.Contains(got.Diff, "\x1b[") {
		t.Fatalf("retrato incorreto: %+v", got)
	}
}

func TestGetGitDiffNaoRepositorioDevolve200ComEstado(t *testing.T) {
	f := &fakeLauncher{gitDiff: session.GitDiff{Dir: "/tmp", State: "not_a_repository", Files: []session.GitFileChange{}}}
	rec := do(t, f, http.MethodGet, "/machines/macbook/git/diff?dir=%2Ftmp", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, esperava 200: %s", rec.Code, rec.Body.String())
	}
	var got session.GitDiff
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.State != "not_a_repository" || got.Files == nil || got.Diff != "" {
		t.Fatalf("estado não-repo incorreto: %+v", got)
	}
}

func TestGetGitDiffSemDirDa400(t *testing.T) {
	rec := do(t, &fakeLauncher{}, http.MethodGet, "/machines/macbook/git/diff", "")
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "bad_request") {
		t.Fatalf("esperava 400 bad_request, veio %d: %s", rec.Code, rec.Body.String())
	}
}

func TestGetGitDiffMaquinaDesconhecidaDa404(t *testing.T) {
	f := &fakeLauncher{gitErr: launcher.ErrUnknownMachine}
	rec := do(t, f, http.MethodGet, "/machines/nope/git/diff?dir=%2Frepo", "")
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Fatalf("esperava 404 unknown_machine, veio %d: %s", rec.Code, rec.Body.String())
	}
}

func TestGetGitDiffFalhaRemotaDa502(t *testing.T) {
	f := &fakeLauncher{gitErr: errors.New("ssh: timeout")}
	rec := do(t, f, http.MethodGet, "/machines/macbook/git/diff?dir=%2Frepo", "")
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "git_failed") {
		t.Fatalf("esperava 502 git_failed, veio %d: %s", rec.Code, rec.Body.String())
	}
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

// TestAnswerRoutesToLauncher cobre o contrato REST de POST /sessions/{id}/answer:
// decodifica {"answers":[{"question":"...","selected":[...]}]} e repassa ao
// Launcher.Answer.
func TestAnswerRoutesToLauncher(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/sessions/abc/answer", `{"answers":[{"question":"Qual cor você prefere?","selected":["Vermelho"]}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotAnswerID != "abc" {
		t.Errorf("Answer recebeu id=%q, quero \"abc\"", f.gotAnswerID)
	}
	if len(f.gotAnswers) != 1 || f.gotAnswers[0].Question != "Qual cor você prefere?" || len(f.gotAnswers[0].Selected) != 1 || f.gotAnswers[0].Selected[0] != "Vermelho" {
		t.Errorf("Answer recebeu answers=%+v inesperado", f.gotAnswers)
	}
}

// TestAnswerMultiSelectPassesAllLabels cobre a seleção múltipla: todos os
// rótulos escolhidos chegam ao Launcher (quem junta com ", " é o launcher, não
// o handler).
func TestAnswerMultiSelectPassesAllLabels(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/sessions/abc/answer", `{"answers":[{"question":"Quais linguagens?","selected":["Go","Swift"]}]}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if len(f.gotAnswers) != 1 || len(f.gotAnswers[0].Selected) != 2 {
		t.Fatalf("Answer recebeu answers=%+v, quero 2 selecionados", f.gotAnswers)
	}
	if f.gotAnswers[0].Selected[0] != "Go" || f.gotAnswers[0].Selected[1] != "Swift" {
		t.Errorf("Selected = %+v, quero [Go Swift]", f.gotAnswers[0].Selected)
	}
}

// TestAnswerBadRequest cobre validação: id vazio (via rota, nunca ocorre no
// mux real mas defensivo), corpo inválido, answers vazio, question vazia e
// selected vazio → 400, sem chamar o Launcher.
func TestAnswerBadRequest(t *testing.T) {
	f := &fakeLauncher{}
	bodies := []string{
		`{não é json`,
		`{}`,
		`{"answers":[]}`,
		`{"answers":[{"question":"","selected":["a"]}]}`,
		`{"answers":[{"question":"q","selected":[]}]}`,
	}
	for _, body := range bodies {
		rec := do(t, f, http.MethodPost, "/sessions/abc/answer", body)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("body %q => status %d, quero 400", body, rec.Code)
		}
	}
}

// TestAnswerErrorStatuses cobre o mesmo mapeamento de erro do Approve/Deny:
// ErrUnknownSession → 404, ErrStaleState → 409.
func TestAnswerErrorStatuses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"unknown", launcher.ErrUnknownSession, http.StatusNotFound, "unknown_session"},
		{"stale", launcher.ErrStaleState, http.StatusConflict, "stale_state"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{answerErr: c.err}
			rec := do(t, f, http.MethodPost, "/sessions/abc/answer", `{"answers":[{"question":"q","selected":["a"]}]}`)
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, quero %d", rec.Code, c.wantStatus)
			}
			assertErrorCode(t, rec.Body.Bytes(), c.wantCode)
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

// TestInterruptReturnsEffect cobre o contrato de POST /sessions/{id}/interrupt:
// o corpo de sucesso traz `effect` ("paused" ou "ended") pra UI rotular certo
// (card 6b74500a1fd9a1f2) — não é só {"ok":true} como approve/deny.
func TestInterruptReturnsEffect(t *testing.T) {
	cases := []struct {
		name       string
		effect     launcher.InterruptEffect
		wantEffect string
	}{
		{"paused (tmux)", launcher.InterruptEffectPaused, "paused"},
		{"ended (pipe-mode)", launcher.InterruptEffectEnded, "ended"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{interruptEffect: c.effect}
			rec := do(t, f, http.MethodPost, "/sessions/abc/interrupt", "")
			if rec.Code != http.StatusOK {
				t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
			}
			if f.gotInterruptID != "abc" {
				t.Errorf("Interrupt recebeu id=%q, quero \"abc\"", f.gotInterruptID)
			}
			var resp struct {
				OK     bool   `json:"ok"`
				Effect string `json:"effect"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
				t.Fatalf("corpo inválido: %v", err)
			}
			if !resp.OK || resp.Effect != c.wantEffect {
				t.Errorf("corpo = %+v, quero ok=true effect=%q", resp, c.wantEffect)
			}
		})
	}
}

// TestInterruptErrorStatuses cobre o mapeamento de erro: sessão desconhecida,
// fora de running (stale) e sem canal vivo (pipe-mode já morto) → 404/409/409.
func TestInterruptErrorStatuses(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"unknown", launcher.ErrUnknownSession, http.StatusNotFound, "unknown_session"},
		{"stale", launcher.ErrStaleState, http.StatusConflict, "stale_state"},
		{"no handle", launcher.ErrNoHandle, http.StatusConflict, "no_live_session"},
		{"unknown machine (tmux)", launcher.ErrUnknownMachine, http.StatusNotFound, "unknown_machine"},
		{"tmux failed", launcher.ErrDiscoverFailed, http.StatusBadGateway, "tmux_failed"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{interruptErr: c.err}
			rec := do(t, f, http.MethodPost, "/sessions/abc/interrupt", "")
			if rec.Code != c.wantStatus {
				t.Fatalf("status = %d, quero %d (corpo: %s)", rec.Code, c.wantStatus, rec.Body.String())
			}
			assertErrorCode(t, rec.Body.Bytes(), c.wantCode)
		})
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

// TestResolveOK cobre o caminho feliz de POST /sessions/{id}/resolve: o CAS
// do Launcher venceu, a sessão saiu de needs_you → done.
func TestResolveOK(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/sessions/abc/resolve", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotResolveID != "abc" {
		t.Errorf("Resolve recebeu id=%q, quero \"abc\"", f.gotResolveID)
	}
}

// TestResolveUnknownSession cobre sessão inexistente: 404 unknown_session,
// distinto do 409 de perda de CAS — a usuária precisa saber a diferença entre
// "a sessão sumiu" e "só perdeu a corrida".
func TestResolveUnknownSession(t *testing.T) {
	f := &fakeLauncher{resolveErr: launcher.ErrUnknownSession}
	rec := do(t, f, http.MethodPost, "/sessions/ghost/resolve", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404 (corpo: %s)", rec.Code, rec.Body.String())
	}
	assertErrorCode(t, rec.Body.Bytes(), "unknown_session")
}

// TestResolveStaleStateReturnsWinner cobre a perda do CAS (Opção 2, "falha e
// conta" — decisão de 16/08): 409 stale_state carregando o estado VENCEDOR,
// para o app dar refresh e mostrar o que de fato ganhou em vez do optimistic
// update que já fez na lista.
func TestResolveStaleStateReturnsWinner(t *testing.T) {
	cases := []struct {
		name    string
		current session.State
	}{
		// Sem caso "done": desde [16/08/2026] o Launcher trata sessão já
		// concluída como no-op idempotente (200), então done nunca chega aqui
		// como vencedor de stale — ver TestResolveJaConcluidaEhNoOpIdempotente.
		{"perdeu para error", session.StateError},
		{"perdeu para running", session.StateRunning},
		{"perdeu para idle", session.StateIdle},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeLauncher{resolveErr: &launcher.StaleStateError{Current: c.current}}
			rec := do(t, f, http.MethodPost, "/sessions/abc/resolve", "")
			if rec.Code != http.StatusConflict {
				t.Fatalf("status = %d, quero 409 (corpo: %s)", rec.Code, rec.Body.String())
			}
			var resp struct {
				Error        string `json:"error"`
				CurrentState string `json:"current_state"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
				t.Fatalf("corpo inválido: %v (%s)", err, rec.Body.String())
			}
			if resp.Error != "stale_state" {
				t.Errorf("error = %q, quero \"stale_state\"", resp.Error)
			}
			if resp.CurrentState != string(c.current) {
				t.Errorf("current_state = %q, quero %q", resp.CurrentState, c.current)
			}
			// errors.Is(err, ErrStaleState) tem que continuar funcionando para
			// quem só olha o sentinel (Unwrap preserva a compatibilidade).
			if !errors.Is(f.resolveErr, launcher.ErrStaleState) {
				t.Errorf("StaleStateError não desembrulha para ErrStaleState")
			}
		})
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

func TestReplyRoutesText(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/sessions/s1/reply", `{"text":"sim, prossiga"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200 (corpo: %s)", rec.Code, rec.Body.String())
	}
	if f.gotInputID != "s1" || f.gotInputText != "sim, prossiga" {
		t.Errorf("Reply recebeu id=%q text=%q", f.gotInputID, f.gotInputText)
	}
	rec = do(t, f, http.MethodPost, "/sessions/s1/reply", `{"text":""}`)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("texto vazio => %d, quero 400", rec.Code)
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

func TestTmuxNewSession(t *testing.T) {
	f := &fakeLauncher{tmuxNewTarget: "/tmp/tmux-501/defender\t%42"}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/new",
		`{"group":"defender","session":"mike","cwd":"/Users/vanessa/x","agent":"codex"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, queria 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `%42`) {
		t.Fatalf("corpo sem o alvo criado: %s", rec.Body.String())
	}
	if f.gotTmuxAgent != "codex" {
		t.Fatalf("agente = %q, queria codex", f.gotTmuxAgent)
	}
}

// Campo faltando é 400 e NÃO chega ao launcher — criar sessão é efeito colateral
// numa máquina de verdade.
func TestTmuxNewSessionCorpoIncompleto(t *testing.T) {
	f := &fakeLauncher{}
	rec := do(t, f, http.MethodPost, "/machines/macbook/tmux/new",
		`{"group":"defender","session":"","cwd":"/x","agent":"codex"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, queria 400", rec.Code)
	}
	if f.gotTmuxAgent != "" {
		t.Fatal("o launcher foi chamado com corpo inválido")
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
