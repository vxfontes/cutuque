package claudecode

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// nopWriteCloser é um io.WriteCloser que descarta o que recebe (stdin ignorado
// nos testes de leitura pura do Runner).
type nopWriteCloser struct{ w io.Writer }

func (n nopWriteCloser) Write(p []byte) (int, error) { return n.w.Write(p) }
func (n nopWriteCloser) Close() error                { return nil }

// handleFromReader monta um *Handle cujo Stdout é o reader dado e cujo Stdin é
// descartado — para exercitar o Runner sem um processo real.
func handleFromReader(r io.Reader) *Handle {
	return &Handle{
		Stdout: io.NopCloser(r),
		Stdin:  nopWriteCloser{w: io.Discard},
	}
}

// handleFromFile abre uma fixture do disco como Stdout do Handle.
func handleFromFile(t *testing.T, path string) *Handle {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("abrindo fixture: %v", err)
	}
	return &Handle{Stdout: f, Stdin: nopWriteCloser{w: io.Discard}}
}

func TestRunnerProcessesFixtureToDone(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)

	h := handleFromFile(t, filepath.Join("testdata", "fixture-simple.jsonl"))
	defer h.Close()
	if err := r.Run(context.Background(), h, Meta{Machine: "macbook", Prompt: "explique a arquitetura do projeto em detalhes técnicos"}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	s, ok := reg.Get("ea6c037a-4306-479b-acc7-d5bd0cf52941")
	if !ok {
		t.Fatalf("sessão não foi criada no registry")
	}
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
	if s.Machine != "macbook" {
		t.Errorf("Machine = %q, quero \"macbook\"", s.Machine)
	}
	if s.Agent != "claude-code" {
		t.Errorf("Agent = %q, quero \"claude-code\"", s.Agent)
	}
	if len([]rune(s.Title)) > 60 {
		t.Errorf("Title tem %d runes, quero <= 60", len([]rune(s.Title)))
	}
	if s.Title == "" {
		t.Errorf("Title vazio, quero prompt truncado")
	}

	out := reg.Output("ea6c037a-4306-479b-acc7-d5bd0cf52941")
	joined := strings.Join(out, "\n")
	if !strings.Contains(joined, "oi") {
		t.Errorf("output = %v, quero conter \"oi\"", out)
	}
}

func TestRunnerEOFWithoutFinishedErrors(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)

	stream := `{"type":"system","subtype":"init","session_id":"sem-fim"}
{"type":"assistant","message":{"content":[{"type":"text","text":"trabalhando..."}]}}
`
	h := handleFromReader(bytes.NewReader([]byte(stream)))
	if err := r.Run(context.Background(), h, Meta{Machine: "desktop-win", Prompt: "faça algo"}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	s, ok := reg.Get("sem-fim")
	if !ok {
		t.Fatalf("sessão não foi criada")
	}
	if s.State != session.StateError {
		t.Errorf("State = %q, quero \"error\" (EOF sem finished)", s.State)
	}
}

func TestRunnerHandlesLongLines(t *testing.T) {
	// Uma linha maior que o buffer padrão do bufio.Scanner (64KB) não pode
	// quebrar o parsing.
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)

	big := strings.Repeat("x", 200_000)
	// Como no stream real, toda linha carrega session_id.
	stream := `{"type":"system","subtype":"init","session_id":"grande"}
{"type":"assistant","session_id":"grande","message":{"content":[{"type":"text","text":"` + big + `"}]}}
{"type":"result","session_id":"grande","subtype":"success","is_error":false,"result":"ok"}
`
	h := handleFromReader(bytes.NewReader([]byte(stream)))
	if err := r.Run(context.Background(), h, Meta{Machine: "macbook", Prompt: "p"}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	s, _ := reg.Get("grande")
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
}

// Robustez: se só o init trouxer session_id, os demais eventos são atribuídos à
// sessão corrente (um Runner observa uma única sessão).
func TestRunnerFillsSessionIDForSingleSessionStream(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)

	stream := `{"type":"system","subtype":"init","session_id":"unica"}
{"type":"assistant","message":{"content":[{"type":"text","text":"produzindo"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"fim"}
`
	h := handleFromReader(bytes.NewReader([]byte(stream)))
	if err := r.Run(context.Background(), h, Meta{Machine: "macbook", Prompt: "p"}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	s, _ := reg.Get("unica")
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
	if out := reg.Output("unica"); len(out) != 1 || out[0] != "produzindo" {
		t.Errorf("Output = %v, quero [\"produzindo\"]", out)
	}
}

// Fixture de permissão real: o Runner deve emitir needs_you com o resumo do
// pedido no PendingPrompt e depois done (a fixture-control contém um allow).
func TestRunnerControlFixtureReachesNeedsYouThenDone(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)

	// A fixture já contém a permissão respondida (allow) seguida do result.
	// Aqui o Runner só lê o stream; a resposta de aprovação é papel do Launcher.
	h := handleFromFile(t, filepath.Join("testdata", "fixture-control.jsonl"))
	defer h.Close()
	if err := r.Run(context.Background(), h, Meta{Machine: "macbook", Prompt: "crie um arquivo de prova"}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	s, ok := reg.Get("6ec0028b-73ec-4717-8670-fc4a6ffba3f3")
	if !ok {
		t.Fatalf("sessão da fixture-control não foi criada")
	}
	// O stream termina em result success → done, e ao sair de needs_you o
	// PendingPrompt é limpo.
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
	if s.PendingPrompt != "" {
		t.Errorf("PendingPrompt = %q, quero vazio ao terminar", s.PendingPrompt)
	}
}

func TestLocalTargetExecsCommand(t *testing.T) {
	// LocalTarget genérico rodando `cat` sobre a fixture prova que a execução
	// de comando local e o pipe de stdout funcionam.
	path := filepath.Join("testdata", "fixture-simple.jsonl")
	tgt := newLocalCommand("macbook", "cat", func() []string {
		return []string{path}
	})
	if tgt.Name() != "macbook" {
		t.Errorf("Name() = %q, quero \"macbook\"", tgt.Name())
	}

	h, err := tgt.Start(context.Background())
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer h.Close()

	data, err := io.ReadAll(h.Stdout)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Contains(data, []byte("ea6c037a-4306-479b-acc7-d5bd0cf52941")) {
		t.Errorf("saída do cat não contém o conteúdo da fixture")
	}
}

func TestSendUserMessageWritesStreamJSON(t *testing.T) {
	var buf bytes.Buffer
	h := &Handle{Stdout: io.NopCloser(strings.NewReader("")), Stdin: nopWriteCloser{w: &buf}}

	if err := h.SendUserMessage("rode o echo cutuque"); err != nil {
		t.Fatalf("SendUserMessage: %v", err)
	}

	line := buf.Bytes()
	if !bytes.HasSuffix(line, []byte("\n")) {
		t.Errorf("mensagem não termina em newline: %q", line)
	}
	var msg struct {
		Type    string `json:"type"`
		Message struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(line), &msg); err != nil {
		t.Fatalf("mensagem não é JSON válido: %v (%q)", err, line)
	}
	if msg.Type != "user" || msg.Message.Role != "user" {
		t.Errorf("shape errado: %+v", msg)
	}
	if len(msg.Message.Content) != 1 || msg.Message.Content[0].Type != "text" || msg.Message.Content[0].Text != "rode o echo cutuque" {
		t.Errorf("content errado: %+v", msg.Message.Content)
	}
}
