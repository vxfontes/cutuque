package launcher

import (
	"bufio"
	"context"
	"encoding/json"
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
	// lastModel captura o `model` recebido no último Start (p/ testar que o
	// resume reusa o modelo da sessão — SEC-109).
	lastModel string
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

func (s *scriptTarget) Start(_ context.Context, _, _, model, _, _, prompt string) (*claudecode.Handle, error) {
	s.lastModel = model
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
	_, err := l.Launch(context.Background(), "inexistente", "claude-code", "faça algo", "", "", "", "")
	if err != ErrUnknownMachine {
		t.Errorf("err = %v, quero ErrUnknownMachine", err)
	}
}

func TestLaunchUnknownAgent(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, _ := newTestLauncher(tgt)
	_, err := l.Launch(context.Background(), "macbook", "codex", "faça algo", "", "", "", "")
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

	_, err := l.Launch(context.Background(), "macbook", "claude-code", "faça algo", "", "", "", "")
	if err != ErrLaunchTimeout {
		t.Errorf("err = %v, quero ErrLaunchTimeout", err)
	}
}

func TestApproveWritesExactControlResponseAndResumes(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	s, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", "", "")
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", "", ""); err != nil {
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

// askUserQuestionLine e wantAnswer* espelham o fixture REAL da CLI 2.1.206
// (capturado empiricamente) e a resposta EXATA que o hub deve escrever —
// contrato verificado de ponta a ponta com o SDK oficial.
const (
	askReqID            = "f8a9ad13-7d58-4da2-af84-a59079a6047b"
	askToolUseID        = "toolu_016tGouKiqK5akLjpwsnByXx"
	askQuestionsInput   = `{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Vermelho","description":"Cor quente, vibrante e intensa."},{"label":"Verde","description":"Cor da natureza, calma e equilibrada."},{"label":"Azul","description":"Cor fria, serena e tranquila."}],"multiSelect":false}]}`
	askUserQuestionLine = `{"type":"control_request","request_id":"` + askReqID + `","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":` + askQuestionsInput + `,"tool_use_id":"` + askToolUseID + `","requires_user_interaction":true}}`

	wantAnswerSingle = `{"type":"control_response","response":{"subtype":"success","request_id":"` + askReqID + `","response":{"behavior":"allow","updatedInput":{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Vermelho","description":"Cor quente, vibrante e intensa."},{"label":"Verde","description":"Cor da natureza, calma e equilibrada."},{"label":"Azul","description":"Cor fria, serena e tranquila."}],"multiSelect":false}],"answers":{"Qual cor você prefere?":"Vermelho"}},"toolUseID":"` + askToolUseID + `"}}}`
)

// askUserQuestionScript emite init + o control_request de AskUserQuestion,
// captura o control_response e então emite o result.
func askUserQuestionScript(stdout io.Writer, stdin *bufio.Reader, captured chan<- string) {
	_, _ = stdin.ReadString('\n') // consome o prompt inicial
	_, _ = io.WriteString(stdout, initLine+"\n")
	_, _ = io.WriteString(stdout, askUserQuestionLine+"\n")
	resp, _ := stdin.ReadString('\n')
	captured <- trimNL(resp)
	_, _ = io.WriteString(stdout, resultLine+"\n")
}

// TestAnswerWritesExactControlResponseSingle cobre a seleção ÚNICA: o
// control_response escrito no stdin deve ecoar `questions` inalterado e
// `answers` com o rótulo escolhido (string, sem array), mais o toolUseID.
func TestAnswerWritesExactControlResponseSingle(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha uma cor", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})
	got, _ := reg.Get(sid)
	if len(got.PendingQuestions) != 1 || got.PendingQuestions[0].Question != "Qual cor você prefere?" {
		t.Fatalf("PendingQuestions = %+v, quero a pergunta da fixture", got.PendingQuestions)
	}

	err := l.Answer(sid, []session.QuestionAnswer{{Question: "Qual cor você prefere?", Selected: []string{"Vermelho"}}})
	if err != nil {
		t.Fatalf("Answer: %v", err)
	}

	select {
	case resp := <-tgt.captured:
		if resp != wantAnswerSingle {
			t.Errorf("control_response =\n  %s\nquero:\n  %s", resp, wantAnswerSingle)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou o control_response de Answer")
	}

	waitFor(t, func() bool {
		g, _ := reg.Get(sid)
		return g.State == session.StateDone
	})
	final, _ := reg.Get(sid)
	if len(final.PendingQuestions) != 0 {
		t.Errorf("PendingQuestions = %+v, quero vazio após responder", final.PendingQuestions)
	}
}

// TestAnswerJoinsMultiSelectWithComma cobre a seleção MÚLTIPLA: os rótulos
// escolhidos viram uma STRING única, juntados com ", " (nunca um array) —
// verificado de ponta a ponta com o SDK oficial.
func TestAnswerJoinsMultiSelectWithComma(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha cores", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	if err := l.Answer(sid, []session.QuestionAnswer{{Question: "Qual cor você prefere?", Selected: []string{"Vermelho", "Azul"}}}); err != nil {
		t.Fatalf("Answer: %v", err)
	}

	select {
	case resp := <-tgt.captured:
		var body struct {
			Response struct {
				Response struct {
					Behavior     string `json:"behavior"`
					UpdatedInput struct {
						Answers map[string]string `json:"answers"`
					} `json:"updatedInput"`
					ToolUseID string `json:"toolUseID"`
				} `json:"response"`
			} `json:"response"`
		}
		if err := json.Unmarshal([]byte(resp), &body); err != nil {
			t.Fatalf("control_response inválido: %v (%s)", err, resp)
		}
		if body.Response.Response.Behavior != "allow" {
			t.Errorf("behavior = %q, quero allow", body.Response.Response.Behavior)
		}
		if got := body.Response.Response.UpdatedInput.Answers["Qual cor você prefere?"]; got != "Vermelho, Azul" {
			t.Errorf("answers[...] = %q, quero \"Vermelho, Azul\" (juntado com \", \")", got)
		}
		if body.Response.Response.ToolUseID != askToolUseID {
			t.Errorf("toolUseID = %q, quero %q", body.Response.Response.ToolUseID, askToolUseID)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou o control_response de Answer")
	}
}

// TestAnswerRejectsWhenPendingIsNotAskUserQuestion: chamar /answer num pedido
// COMUM de permissão (Bash) é recusado (SEC-111) — senão o hub mandaria "allow"
// pro tool_use_id do Bash com o input trocado por {questions,answers}. O
// pendente é devolvido, então Approve/Deny ainda funcionam.
func TestAnswerRejectsWhenPendingIsNotAskUserQuestion(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: permissionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "cria arquivo", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	err := l.Answer(sid, []session.QuestionAnswer{{Question: "qualquer", Selected: []string{"x"}}})
	if err != ErrStaleState {
		t.Fatalf("Answer num pending de Bash: err = %v, quero ErrStaleState", err)
	}
	// Pendente devolvido: segue em needs_you e Approve ainda deve funcionar.
	if got, _ := reg.Get(sid); got.State != session.StateNeedsYou {
		t.Errorf("estado = %q, quero needs_you (pendente devolvido)", got.State)
	}
}

// TestAnswerRejectsUnknownQuestionText: responder com um texto de pergunta que
// não existe no pedido é ErrInvalidAnswer (a chave não casaria com nada e a
// pergunta real ficaria sem resposta silenciosamente).
func TestAnswerRejectsUnknownQuestionText(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	err := l.Answer(sid, []session.QuestionAnswer{{Question: "pergunta inexistente", Selected: []string{"Vermelho"}}})
	if err != ErrInvalidAnswer {
		t.Fatalf("Answer com pergunta desconhecida: err = %v, quero ErrInvalidAnswer", err)
	}
}

// TestApproveRejectsAskUserQuestion: Approve (allow binário) numa pergunta é
// recusado — aprovar sem answers rodaria a ferramenta sem resposta. Usa /answer.
func TestApproveRejectsAskUserQuestion(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	if err := l.Approve(sid); err != ErrStaleState {
		t.Fatalf("Approve numa pergunta: err = %v, quero ErrStaleState", err)
	}
}

// TestDenyAskUserQuestionAllowed: recusar (deny) uma pergunta é VÁLIDO — o app
// pode cancelar a pergunta. O control_response é behavior=deny com o toolUseID.
func TestDenyAskUserQuestionAllowed(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	if err := l.Deny(sid); err != nil {
		t.Fatalf("Deny numa pergunta: err = %v, quero nil", err)
	}
	select {
	case resp := <-tgt.captured:
		var body struct {
			Response struct {
				Response struct {
					Behavior  string `json:"behavior"`
					ToolUseID string `json:"toolUseID"`
				} `json:"response"`
			} `json:"response"`
		}
		if err := json.Unmarshal([]byte(resp), &body); err != nil {
			t.Fatalf("control_response inválido: %v (%s)", err, resp)
		}
		if body.Response.Response.Behavior != "deny" {
			t.Errorf("behavior = %q, quero deny", body.Response.Response.Behavior)
		}
		if body.Response.Response.ToolUseID != askToolUseID {
			t.Errorf("toolUseID = %q, quero %q", body.Response.Response.ToolUseID, askToolUseID)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("não capturou o control_response de Deny")
	}
}

// TestAnswerUnknownSession: sessão inexistente → ErrUnknownSession (mesmo
// mapeamento de erro do Approve/Deny).
func TestAnswerUnknownSession(t *testing.T) {
	l, _ := newTestLauncher(nil)
	if err := l.Answer("fantasma", []session.QuestionAnswer{{Question: "q", Selected: []string{"a"}}}); err != ErrUnknownSession {
		t.Errorf("err = %v, quero ErrUnknownSession", err)
	}
}

// TestAnswerStaleWhenNotNeedsYou: sessão que não está em needs_you → ErrStaleState.
func TestAnswerStaleWhenNotNeedsYou(t *testing.T) {
	l, reg := newTestLauncher(nil)
	now := time.Now()
	reg.Add(session.Session{ID: "s", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	if err := l.Answer("s", []session.QuestionAnswer{{Question: "q", Selected: []string{"a"}}}); err != ErrStaleState {
		t.Errorf("err = %v, quero ErrStaleState (não está em needs_you)", err)
	}
}

// TestAnswerTwiceIsStale: responder duas vezes é a mesma reivindicação atômica
// do Approve/Deny — a segunda chega tarde (o pendente já foi consumido).
func TestAnswerTwiceIsStale(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: askUserQuestionScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)
	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "escolha uma cor", "", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		got, _ := reg.Get(sid)
		return got.State == session.StateNeedsYou
	})

	if err := l.Answer(sid, []session.QuestionAnswer{{Question: "Qual cor você prefere?", Selected: []string{"Verde"}}}); err != nil {
		t.Fatalf("Answer: %v", err)
	}
	<-tgt.captured

	if err := l.Answer(sid, []session.QuestionAnswer{{Question: "Qual cor você prefere?", Selected: []string{"Azul"}}}); err != ErrStaleState {
		t.Errorf("2ª Answer err = %v, quero ErrStaleState", err)
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeira tarefa", "", "", "", ""); err != nil {
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "crie um arquivo", "", "", "", ""); err != nil {
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeira tarefa", "", "", "", ""); err != nil {
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

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "primeiro prompt", "", "", "", ""); err != nil {
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
		_, err := l.Adopt("macbook", bad, "/Users/example/proj", "titulo", "")
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
	s, err := l.Adopt("macbook", id, "/Users/example/proj", "arruma o build", "")
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
	if _, err := l.Adopt("macbook", id, "/Users/example/proj", "titulo", ""); err != nil {
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

	if _, err := l.Adopt("macbook", id, "/x", "t", ""); err != nil {
		t.Fatalf("Adopt 1: %v", err)
	}
	if _, err := l.Adopt("macbook", id, "/x", "t", ""); err != nil {
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
	if _, err := l.Adopt("macbook", id, "/x", "t", ""); err != nil {
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
	_, err := l.Adopt("ghost", "7b6ff87d-99ca-4bd4-a0e9-e01a4ba689af", "/x", "t", "")
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

// TestSendTextRejectsHandleWithoutStdin cobre o fix do achado #1 da ludmilla:
// um Handle vivo SEM stdin (Codex one-shot, turno em andamento) não pode receber
// SendUserMessage — SendText deve devolver ErrNoHandle, nunca estourar nil deref.
func TestSendTextRejectsHandleWithoutStdin(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	l := New(eng, reg, map[string]map[string]claudecode.Target{})
	reg.AddIfAbsent(session.Session{ID: "cx1", Machine: "macbook", Agent: "codex", State: session.StateRunning})
	// Handle "vivo" mas com Stdin nil (como o Codex): AcceptsInput() == false.
	r, _ := io.Pipe()
	l.setHandle("cx1", &claudecode.Handle{Stdout: r})

	if err := l.SendText("cx1", "oi"); err != ErrNoHandle {
		t.Errorf("err = %v, quero ErrNoHandle (handle sem stdin)", err)
	}
}

// TestResumeMarksErroredWhenProcessDiesSilently cobre o fix do achado #2: se o
// processo retomado morre ANTES de emitir qualquer evento (EOF sem
// session_started), a sessão não pode ficar congelada — o Runner marca Errored
// usando o id conhecido do resume (Meta.SessionID).
func TestResumeMarksErroredWhenProcessDiesSilently(t *testing.T) {
	const id = "11111111-2222-3333-4444-555555555555"
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		// Lê o prompt (destrava o SendUserMessage do Start) e sai: EOF sem emitir
		// nada — simula o `codex`/`claude` que morre sem produzir stream.
		run: func(_ io.Writer, stdin *bufio.Reader, _ chan<- string) { _, _ = stdin.ReadString('\n') },
	}
	l, reg := newTestLauncher(tgt)
	reg.AddIfAbsent(session.Session{ID: id, Machine: "macbook", Agent: "claude-code", State: session.StateDone})

	if err := l.SendText(id, "continua"); err != nil {
		t.Fatalf("SendText (resume): %v", err)
	}
	waitFor(t, func() bool {
		s, _ := reg.Get(id)
		return s.State == session.StateError
	})
}

// TestResumeReusesSessionModel cobre o fix do SEC-109: o modelo escolhido no
// launch é persistido em session.Model e reusado no resume (o OpenCode exige -m
// em toda invocação; sem isto a continuação cairia no default).
func TestResumeReusesSessionModel(t *testing.T) {
	const id = "22222222-3333-4444-5555-666666666666"
	tgt := &scriptTarget{
		name:     "macbook",
		captured: make(chan string, 1),
		// lê o prompt (destrava o Start) e sai — o teste só checa o model recebido.
		run: func(_ io.Writer, stdin *bufio.Reader, _ chan<- string) { _, _ = stdin.ReadString('\n') },
	}
	l, reg := newTestLauncher(tgt)
	reg.AddIfAbsent(session.Session{ID: id, Machine: "macbook", Agent: "claude-code", State: session.StateDone, Model: "openai/gpt-5.4-mini"})

	if err := l.SendText(id, "continua"); err != nil {
		t.Fatalf("SendText (resume): %v", err)
	}
	// resume chama Start de forma síncrona antes de retornar.
	if tgt.lastModel != "openai/gpt-5.4-mini" {
		t.Errorf("model no resume = %q, quero o modelo da sessão (openai/gpt-5.4-mini)", tgt.lastModel)
	}
}
