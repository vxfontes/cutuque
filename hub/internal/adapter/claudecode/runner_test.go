package claudecode

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// fileTarget é um Target fake que "roda" fazendo cat de uma fixture.
type fileTarget struct {
	name string
	path string
}

func (f fileTarget) Name() string { return f.name }
func (f fileTarget) Start(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return os.Open(f.path)
}

// bytesTarget é um Target fake que devolve bytes fixos.
type bytesTarget struct {
	name string
	data []byte
}

func (b bytesTarget) Name() string { return b.name }
func (b bytesTarget) Start(ctx context.Context, prompt string) (io.ReadCloser, error) {
	return io.NopCloser(bytes.NewReader(b.data)), nil
}

func TestRunnerProcessesFixtureToDone(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng, reg)

	tgt := fileTarget{name: "macbook", path: filepath.Join("testdata", "fixture-simple.jsonl")}
	if err := r.Run(context.Background(), tgt, "explique a arquitetura do projeto em detalhes técnicos"); err != nil {
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
	r := NewRunner(eng, reg)

	stream := `{"type":"system","subtype":"init","session_id":"sem-fim"}
{"type":"assistant","message":{"content":[{"type":"text","text":"trabalhando..."}]}}
`
	tgt := bytesTarget{name: "desktop-win", data: []byte(stream)}
	if err := r.Run(context.Background(), tgt, "faça algo"); err != nil {
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
	r := NewRunner(eng, reg)

	big := strings.Repeat("x", 200_000)
	// Como no stream real, toda linha carrega session_id.
	stream := `{"type":"system","subtype":"init","session_id":"grande"}
{"type":"assistant","session_id":"grande","message":{"content":[{"type":"text","text":"` + big + `"}]}}
{"type":"result","session_id":"grande","subtype":"success","is_error":false,"result":"ok"}
`
	tgt := bytesTarget{name: "macbook", data: []byte(stream)}
	if err := r.Run(context.Background(), tgt, "p"); err != nil {
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
	r := NewRunner(eng, reg)

	stream := `{"type":"system","subtype":"init","session_id":"unica"}
{"type":"assistant","message":{"content":[{"type":"text","text":"produzindo"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"fim"}
`
	tgt := bytesTarget{name: "macbook", data: []byte(stream)}
	if err := r.Run(context.Background(), tgt, "p"); err != nil {
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

func TestLocalTargetExecsCommand(t *testing.T) {
	// LocalTarget genérico rodando `cat` sobre a fixture prova que a execução
	// de comando local e o pipe de stdout funcionam.
	path := filepath.Join("testdata", "fixture-simple.jsonl")
	tgt := newLocalCommand("macbook", "cat", func(prompt string) []string {
		return []string{path}
	})
	if tgt.Name() != "macbook" {
		t.Errorf("Name() = %q, quero \"macbook\"", tgt.Name())
	}

	rc, err := tgt.Start(context.Background(), "ignorado")
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer rc.Close()

	data, err := io.ReadAll(rc)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Contains(data, []byte("ea6c037a-4306-479b-acc7-d5bd0cf52941")) {
		t.Errorf("saída do cat não contém o conteúdo da fixture")
	}
}

func TestSSHTargetIsStub(t *testing.T) {
	tgt := NewSSHTarget("remote")
	if tgt.Name() != "remote" {
		t.Errorf("Name() = %q, quero \"remote\"", tgt.Name())
	}
	if _, err := tgt.Start(context.Background(), "p"); err == nil {
		t.Errorf("SSHTarget.Start err = nil, quero erro de não-implementado")
	}
}
