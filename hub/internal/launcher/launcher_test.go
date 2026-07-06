package launcher

import (
	"bufio"
	"context"
	"io"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/event"
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
	// transcript é o histórico devolvido por Transcript (import ao adotar).
	// nil → sem histórico. transcriptErr simula falha de leitura.
	transcript    []claudecode.TranscriptChunk
	transcriptErr error
}

func (s *scriptTarget) Name() string { return s.name }

func (s *scriptTarget) Kind() string { return "claude-code" }

func (s *scriptTarget) NewRunner(app claudecode.Applier) *claudecode.Runner {
	return claudecode.NewRunner(app)
}

// Transcript satisfaz claudecode.Transcriber: devolve o histórico canned (usado
// pelo teste de import ao adotar).
func (s *scriptTarget) Transcript(_ context.Context, _ string) ([]claudecode.TranscriptChunk, error) {
	return s.transcript, s.transcriptErr
}

func (s *scriptTarget) Start(_ context.Context, _, _, _, _, prompt string) (*claudecode.Handle, error) {
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	go func() {
		defer stdoutW.Close()
		s.run(stdoutW, bufio.NewReader(stdinR), s.captured)
	}()
	h := &claudecode.Handle{Stdout: stdoutR, Stdin: stdinW}
	// O Launcher não manda mais o prompt após o Start — o Start de cada agente
	// o envia. Espelha isso no fake para o script consumir o prompt inicial.
	if prompt != "" {
		if err := h.SendUserMessage(prompt); err != nil {
			return nil, err
		}
	}
	return h, nil
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
	targets := map[string]map[string]claudecode.Target{}
	if tgt != nil {
		targets[tgt.Name()] = map[string]claudecode.Target{tgt.Kind(): tgt}
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
	_, err := l.Launch(context.Background(), "inexistente", "claude-code", "faça algo", "", "", "")
	if err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine", err)
	}
}

func TestLaunchUnknownAgent(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, _ := newTestLauncher(tgt)
	_, err := l.Launch(context.Background(), "macbook", "codex", "faça algo", "", "", "")
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

	_, err := l.Launch(context.Background(), "macbook", "claude-code", "faça algo", "", "", "")
	if err != ErrLaunchTimeout {
		t.Errorf("err = %v, quero ErrLaunchTimeout", err)
	}
}

func TestApproveWritesExactControlResponseAndResumes(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	s, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", "")
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", ""); err != nil {
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

// TestSendTextEndedResumes: sessão encerrada (sem handle vivo) → SendText tenta
// RETOMAR (--resume) na máquina da sessão. Sem target registrado para essa
// máquina, o caminho de resume falha com ErrUnknownMachine (não ErrNoHandle —
// a semântica antiga). Prova que SendText não erra "sem canal", e sim resume.
func TestSendTextEndedResumes(t *testing.T) {
	l, reg := newTestLauncher(nil) // sem targets
	now := time.Now()
	reg.Add(session.Session{ID: "s", Machine: "macbook", State: session.StateDone, CreatedAt: now, UpdatedAt: now})
	if err := l.SendText("s", "continue"); err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine (caminho de resume)", err)
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeira tarefa", "", "", ""); err != nil {
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

// TestLaunchEchoesPromptAsUserOutputChunk cobre o eco do prompt inicial: o
// texto que a usuária mandou tem que aparecer no output (kind "user"), ANTES
// de qualquer resposta do agente, pra sustentar o transcript no app.
func TestLaunchEchoesPromptAsUserOutputChunk(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}

	out := reg.Output(sid)
	if len(out) == 0 {
		t.Fatalf("Output vazio, quero pelo menos o eco do prompt")
	}
	if out[0].Kind != event.KindUser || out[0].Text != "crie um arquivo" {
		t.Errorf("Output[0] = %+v, quero {kind:user, text:\"crie um arquivo\"}", out[0])
	}
}

// TestSendTextEchoesMessageAsUserOutputChunk cobre o eco no caminho VIVO do
// SendText: o texto da usuária tem que ficar registrado como output kind
// "user" antes de qualquer resposta nova do agente.
func TestSendTextEchoesMessageAsUserOutputChunk(t *testing.T) {
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeira tarefa", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		_, ok := reg.Get(sid)
		return ok
	})

	if err := l.SendText(sid, "agora faça isso"); err != nil {
		t.Fatalf("SendText: %v", err)
	}
	<-captured // espera o processo receber a mensagem, garantindo que o eco já foi gravado

	out := reg.Output(sid)
	found := false
	for _, c := range out {
		if c.Kind == event.KindUser && c.Text == "agora faça isso" {
			found = true
		}
	}
	if !found {
		t.Errorf("Output = %+v, quero um chunk {kind:user, text:\"agora faça isso\"}", out)
	}
}

// TestResumeEchoesPromptAsUserOutputChunk cobre o eco no caminho de --resume
// (SendText numa sessão já encerrada): o prompt do resume também tem que
// aparecer no output como kind "user".
func TestResumeEchoesPromptAsUserOutputChunk(t *testing.T) {
	callCount := 0
	tgt := &scriptTarget{name: "macbook", captured: make(chan string, 4)}
	tgt.run = func(stdout io.Writer, stdin *bufio.Reader, captured chan<- string) {
		callCount++
		_, _ = stdin.ReadString('\n') // prompt inicial (Launch) ou do resume
		if callCount == 1 {
			_, _ = io.WriteString(stdout, initLine+"\n")
		}
		_, _ = io.WriteString(stdout, resultLine+"\n")
	}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeiro prompt", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		s, _ := reg.Get(sid)
		return s.State == session.StateDone
	})

	if err := l.SendText(sid, "retome por favor"); err != nil {
		t.Fatalf("SendText (resume): %v", err)
	}
	waitFor(t, func() bool {
		s, _ := reg.Get(sid)
		return s.State == session.StateDone
	})

	out := reg.Output(sid)
	found := false
	for _, c := range out {
		if c.Kind == event.KindUser && c.Text == "retome por favor" {
			found = true
		}
	}
	if !found {
		t.Errorf("Output = %+v, quero um chunk {kind:user, text:\"retome por favor\"} do resume", out)
	}
}

// TestAdoptRejectsInvalidID é a defesa em profundidade do SEC-101 na camada do
// Launcher: um id fora do formato de session id (que viraria `--resume <id>`
// num comando remoto) é rejeitado e NADA é registrado.
func TestAdoptRejectsInvalidID(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	for _, bad := range []string{"x; rm -rf ~", "abc$(touch /tmp/x)", "", "id com espaço", "a/b/c"} {
		_, err := l.Adopt("macbook", bad, "/Users/example/proj", "titulo")
		if err != ErrInvalidSessionID {
			t.Errorf("Adopt(id=%q) err = %v, quero ErrInvalidSessionID", bad, err)
		}
		if _, ok := reg.Get(bad); ok {
			t.Errorf("Adopt(id=%q) registrou a sessão mesmo com id inválido", bad)
		}
	}
}

// TestAdoptRegistersValidSession: um UUID válido vira uma sessão idle no
// registry, com cwd/título preservados para o resume posterior.
func TestAdoptRegistersValidSession(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	id := "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"
	s, err := l.Adopt("macbook", id, "/Users/example/proj", "arruma o build")
	if err != nil {
		t.Fatalf("Adopt: %v", err)
	}
	if s.ID != id || s.Machine != "macbook" || s.Cwd != "/Users/example/proj" || s.State != session.StateIdle {
		t.Errorf("session adotada = %+v", s)
	}
	got, ok := reg.Get(id)
	if !ok || got.Cwd != "/Users/example/proj" {
		t.Errorf("sessão não ficou no registry com o cwd: ok=%v got=%+v", ok, got)
	}
}

// TestAdoptImportsTranscript: ao adotar, o histórico do transcript vira output
// da sessão (na ordem), para o chat mostrar as mensagens anteriores ao abrir.
func TestAdoptImportsTranscript(t *testing.T) {
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		transcript: []claudecode.TranscriptChunk{
			{Kind: event.KindUser, Text: "conserta o build"},
			{Kind: event.KindAssistant, Text: "vou rodar os testes"},
			{Kind: event.KindTool, Text: "Bash: go test ./..."},
			{Kind: event.KindToolResult, Text: "ok PASS"},
		},
	}
	l, reg := newTestLauncher(tgt)

	id := "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"
	if _, err := l.Adopt("macbook", id, "/Users/example/proj", "titulo"); err != nil {
		t.Fatalf("Adopt: %v", err)
	}

	out := reg.Output(id)
	if len(out) != 4 {
		t.Fatalf("output = %d chunks, quero 4 (o histórico importado): %+v", len(out), out)
	}
	if out[0].Kind != event.KindUser || out[0].Text != "conserta o build" ||
		out[2].Kind != event.KindTool || out[2].Text != "Bash: go test ./..." {
		t.Errorf("histórico importado fora de ordem/errado: %+v", out)
	}
}

// TestAdoptTwiceDoesNotDuplicateHistory: adotar o mesmo id duas vezes importa o
// histórico UMA vez só (reivindicação atômica via AddIfAbsent — review #3).
func TestAdoptTwiceDoesNotDuplicateHistory(t *testing.T) {
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		transcript: []claudecode.TranscriptChunk{
			{Kind: event.KindUser, Text: "oi"},
			{Kind: event.KindAssistant, Text: "olá"},
		},
	}
	l, reg := newTestLauncher(tgt)
	id := "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"

	if _, err := l.Adopt("macbook", id, "/x", "t"); err != nil {
		t.Fatalf("Adopt 1: %v", err)
	}
	if _, err := l.Adopt("macbook", id, "/x", "t"); err != nil {
		t.Fatalf("Adopt 2: %v", err)
	}
	if out := reg.Output(id); len(out) != 2 {
		t.Errorf("output = %d chunks, quero 2 (histórico importado UMA vez): %+v", len(out), out)
	}
}

// TestImportHistoryLoadsTranscriptOnce: sessão externa já registrada (por hook)
// ganha o histórico sob demanda ao abrir no app, e importar duas vezes NÃO
// duplica (guarda histImport) — ideia da usuária: registrar tudo, recap ao entrar.
func TestImportHistoryLoadsTranscriptOnce(t *testing.T) {
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		transcript: []claudecode.TranscriptChunk{
			{Kind: event.KindUser, Text: "roda o deploy"},
			{Kind: event.KindAssistant, Text: "feito"},
		},
	}
	l, reg := newTestLauncher(tgt)
	id := "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"
	// Sessão pré-registrada por hook (external, sem output ainda).
	reg.Add(session.Session{ID: id, Machine: "macbook", Agent: "claude-code", State: session.StateNeedsYou, External: true})

	if err := l.ImportHistory(id); err != nil {
		t.Fatalf("ImportHistory: %v", err)
	}
	if err := l.ImportHistory(id); err != nil { // 2ª vez: no-op
		t.Fatalf("ImportHistory 2: %v", err)
	}
	if out := reg.Output(id); len(out) != 2 {
		t.Fatalf("output = %d chunks, quero 2 (importado UMA vez): %+v", len(out), out)
	}
}

// TestImportHistoryUnknownSession: sessão desconhecida → erro (não cria nada).
func TestImportHistoryUnknownSession(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", captured: make(chan string, 1)}
	l, _ := newTestLauncher(tgt)
	if err := l.ImportHistory("7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"); err != ErrUnknownSession {
		t.Errorf("erro = %v, quero ErrUnknownSession", err)
	}
}

// TestAdoptTranscriptFailureStillAdopts: falha ao ler o transcript não derruba a
// adoção — a sessão é registrada mesmo sem histórico (degradação graciosa).
func TestAdoptTranscriptFailureStillAdopts(t *testing.T) {
	tgt := &scriptTarget{
		name:          "macbook",
		captured:      make(chan string, 1),
		transcriptErr: context.DeadlineExceeded,
	}
	l, reg := newTestLauncher(tgt)

	id := "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af"
	if _, err := l.Adopt("macbook", id, "/x", "t"); err != nil {
		t.Fatalf("Adopt não devia falhar por causa do transcript: %v", err)
	}
	if _, ok := reg.Get(id); !ok {
		t.Error("sessão não foi registrada apesar da falha do transcript")
	}
	if out := reg.Output(id); len(out) != 0 {
		t.Errorf("output = %+v, quero vazio (transcript falhou)", out)
	}
}

// TestAdoptUnknownMachine: máquina inexistente → ErrUnknownMachine.
func TestAdoptUnknownMachine(t *testing.T) {
	l, _ := newTestLauncher(nil)
	_, err := l.Adopt("ghost", "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af", "/x", "t")
	if err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine", err)
	}
}

// TestDiscoverUnknownMachine: máquina inexistente → ErrUnknownMachine (não
// ErrDiscoverFailed, que é reservado para falha real da descoberta).
func TestDiscoverUnknownMachine(t *testing.T) {
	l, _ := newTestLauncher(nil)
	_, err := l.Discover("ghost")
	if err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine", err)
	}
}
