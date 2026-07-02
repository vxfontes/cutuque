package launcher

import (
	"bufio"
	"context"
	"io"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// --- Fake scriptável -------------------------------------------------------

// scriptTarget é um Target fake e scriptável: uma função `run` recebe o stdout
// (para emitir o stream), o stdin já lido (para capturar o que o Launcher
// escreve) e um canal para devolver o que capturou.
type scriptTarget struct {
	name     string
	run      func(stdout io.Writer, stdin *bufio.Reader, captured chan<- string)
	captured chan string
}

func (s *scriptTarget) Name() string { return s.name }

func (s *scriptTarget) Start(ctx context.Context) (*claudecode.Handle, error) {
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	go func() {
		defer stdoutW.Close()
		s.run(stdoutW, bufio.NewReader(stdinR), s.captured)
	}()
	return &claudecode.Handle{Stdout: stdoutR, Stdin: stdinW}, nil
}

const (
	sid        = "sess-123"
	reqID      = "req-xyz"
	initLine   = `{"type":"system","subtype":"init","session_id":"` + sid + `"}`
	controlLn  = `{"type":"control_request","request_id":"` + reqID + `","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch cutuque.txt","description":"probe"},"description":"probe"}}`
	resultLine = `{"type":"result","subtype":"success","is_error":false,"result":"ok"}`

	wantAllow = `{"type":"control_response","response":{"subtype":"success","request_id":"` + reqID + `","response":{"behavior":"allow","updatedInput":{"command":"touch cutuque.txt","description":"probe"}}}}`
	wantDeny  = `{"type":"control_response","response":{"subtype":"success","request_id":"` + reqID + `","response":{"behavior":"deny","message":"negado pela usuária via Cutuque"}}}`
)

// permissionScript emite init + control_request, espera a resposta (capturando-a)
// e então emite o result.
func permissionScript(stdout io.Writer, stdin *bufio.Reader, captured chan<- string) {
	_, _ = stdin.ReadString('\n') // consome o prompt inicial
	_, _ = io.WriteString(stdout, initLine+"\n")
	_, _ = io.WriteString(stdout, controlLn+"\n")
	resp, _ := stdin.ReadString('\n') // control_response escrito pelo Launcher
	captured <- trimNL(resp)
	_, _ = io.WriteString(stdout, resultLine+"\n")
}

func trimNL(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r') {
		s = s[:len(s)-1]
	}
	return s
}

// newTestLauncher monta um Launcher com o alvo fake sob o nome "macbook".
func newTestLauncher(tgt claudecode.Target) (*Launcher, *registry.Registry) {
	reg := registry.New()
	eng := engine.New(reg)
	targets := map[string]claudecode.Target{}
	if tgt != nil {
		targets[tgt.Name()] = tgt
	}
	return New(eng, reg, targets), reg
}

// waitFor faz polling de cond até virar true ou estourar o timeout.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("condição não satisfeita dentro do timeout")
}

// --- Testes ----------------------------------------------------------------

func TestLaunchUnknownMachine(t *testing.T) {
	l, _ := newTestLauncher(nil)
	_, err := l.Launch(context.Background(), "inexistente", "claude-code", "faça algo")
	if err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine", err)
	}
}

func TestLaunchUnknownAgent(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, _ := newTestLauncher(tgt)
	_, err := l.Launch(context.Background(), "macbook", "codex", "faça algo")
	if err != ErrUnknownAgent {
		t.Errorf("err = %v, quero ErrUnknownAgent", err)
	}
}

func TestLaunchTimeout(t *testing.T) {
	// Alvo que lê o prompt e não emite session_started: Launch deve estourar.
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		run: func(stdout io.Writer, stdin *bufio.Reader, _ chan<- string) {
			_, _ = stdin.ReadString('\n') // consome o prompt e encerra o stream
		},
	}
	l, _ := newTestLauncher(tgt)

	old := launchTimeout
	launchTimeout = 100 * time.Millisecond
	defer func() { launchTimeout = old }()

	_, err := l.Launch(context.Background(), "macbook", "claude-code", "faça algo")
	if err != ErrLaunchTimeout {
		t.Errorf("err = %v, quero ErrLaunchTimeout", err)
	}
}

func TestApproveWritesExactControlResponseAndResumes(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	s, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo")
	if err != nil {
		t.Fatalf("Launch: %v", err)
	}
	if s.ID != sid || s.State != session.StateRunning {
		t.Fatalf("session inicial = %+v, quero id=%s running", s, sid)
	}

	// Chega em needs_you com o texto do pedido exibível (invariante de segurança).
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})
	got, _ := reg.Get(sid)
	if got.PendingPrompt != "Bash: touch cutuque.txt — probe" {
		t.Errorf("PendingPrompt = %q, quero o resumo do pedido", got.PendingPrompt)
	}

	if err := l.Approve(sid); err != nil {
		t.Fatalf("Approve: %v", err)
	}

	// O JSON exato escrito no stdin deve ser o control_response de allow.
	select {
	case resp := <-tgt.captured:
		if resp != wantAllow {
			t.Errorf("control_response =\n  %s\nquero:\n  %s", resp, wantAllow)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou o control_response")
	}

	// Após aprovar: running (e depois done quando o result chega), pending limpo.
	waitFor(t, func() bool {
		g, _ := reg.Get(sid)
		return g.State == session.StateDone
	})
	final, _ := reg.Get(sid)
	if final.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio após responder", final.PendingPrompt)
	}

	// Segunda aprovação: estado obsoleto (já não está em needs_you).
	if err := l.Approve(sid); err != ErrStaleState {
		t.Errorf("segunda Approve err = %v, quero ErrStaleState", err)
	}
}

func TestDenyWritesDenyControlResponse(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo"); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	if err := l.Deny(sid); err != nil {
		t.Fatalf("Deny: %v", err)
	}
	select {
	case resp := <-tgt.captured:
		if resp != wantDeny {
			t.Errorf("control_response =\n  %s\nquero:\n  %s", resp, wantDeny)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou o control_response de deny")
	}
}

func TestApproveUnknownSession(t *testing.T) {
	l, _ := newTestLauncher(nil)
	if err := l.Approve("fantasma"); err != ErrUnknownSession {
		t.Errorf("err = %v, quero ErrUnknownSession", err)
	}
}

func TestApproveStaleWhenNotNeedsYou(t *testing.T) {
	l, reg := newTestLauncher(nil)
	now := time.Now()
	reg.Add(session.Session{ID: "s", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	if err := l.Approve("s"); err != ErrStaleState {
		t.Errorf("err = %v, quero ErrStaleState (não está em needs_you)", err)
	}
}

func TestSendTextNoHandle(t *testing.T) {
	l, reg := newTestLauncher(nil)
	now := time.Now()
	reg.Add(session.Session{ID: "s", State: session.StateDone, CreatedAt: now, UpdatedAt: now})
	if err := l.SendText("s", "continue"); err != ErrNoHandle {
		t.Errorf("err = %v, quero ErrNoHandle", err)
	}
}

func TestSendTextUnknownSession(t *testing.T) {
	l, _ := newTestLauncher(nil)
	if err := l.SendText("fantasma", "oi"); err != ErrUnknownSession {
		t.Errorf("err = %v, quero ErrUnknownSession", err)
	}
}

func TestSendTextDeliversAndResumes(t *testing.T) {
	// Alvo que emite session_started e depois captura a mensagem enviada.
	captured := make(chan string, 1)
	tgt := &scriptTarget{
		name:     "macbook",
		captured: captured,
		run: func(stdout io.Writer, stdin *bufio.Reader, cap chan<- string) {
			_, _ = stdin.ReadString('\n') // prompt inicial
			_, _ = io.WriteString(stdout, initLine+"\n")
			line, _ := stdin.ReadString('\n') // texto enviado via SendText
			cap <- trimNL(line)
			_, _ = io.WriteString(stdout, resultLine+"\n")
		},
	}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeira tarefa"); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		_, ok := reg.Get(sid)
		return ok
	})

	if err := l.SendText(sid, "agora faça isso"); err != nil {
		t.Fatalf("SendText: %v", err)
	}
	select {
	case msg := <-captured:
		if want := `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"agora faça isso"}]}}`; msg != want {
			t.Errorf("mensagem enviada =\n  %s\nquero:\n  %s", msg, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou a mensagem de SendText")
	}
}
