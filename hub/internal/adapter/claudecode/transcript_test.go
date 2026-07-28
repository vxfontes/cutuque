package claudecode

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestParseTranscriptValid: JSON de chunks → []TranscriptChunk.
func TestParseTranscriptValid(t *testing.T) {
	out := []byte(`[{"kind":"user","text":"oi"},{"kind":"assistant","text":"olá"},{"kind":"tool","text":"Bash: ls"},{"kind":"tool_result","text":"a\nb"}]`)
	got, err := parseTranscript(out)
	if err != nil {
		t.Fatalf("parseTranscript: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("len = %d, quero 4", len(got))
	}
	if got[0].Kind != "user" || got[0].Text != "oi" || got[2].Kind != "tool" || got[2].Text != "Bash: ls" {
		t.Errorf("chunks errados: %+v", got)
	}
}

// TestParseTranscriptEmpty: saída vazia (sessão sem transcript) → nil, sem erro.
func TestParseTranscriptEmpty(t *testing.T) {
	for _, in := range []string{"", "  ", "\n"} {
		got, err := parseTranscript([]byte(in))
		if err != nil || got != nil {
			t.Errorf("parseTranscript(%q) = (%v, %v), quero (nil, nil)", in, got, err)
		}
	}
}

// TestParseTranscriptMalformed: JSON inválido → erro.
func TestParseTranscriptMalformed(t *testing.T) {
	if _, err := parseTranscript([]byte(`{quebrado`)); err == nil {
		t.Error("parseTranscript de JSON inválido devia falhar")
	}
}

// TestLocalTranscriptViaFakeProgram: troca `python3` por `cat` sobre uma
// fixture — prova que Transcript parseia a saída do processo em chunks.
func TestLocalTranscriptViaFakeProgram(t *testing.T) {
	dir := t.TempDir()
	fixture := filepath.Join(dir, "chunks.json")
	if err := os.WriteFile(fixture, []byte(`[{"kind":"assistant","text":"pronto"}]`), 0o644); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	got, err := runTranscript(exec.Command("cat", fixture))
	if err != nil {
		t.Fatalf("runTranscript: %v", err)
	}
	if len(got) != 1 || got[0].Kind != "assistant" || got[0].Text != "pronto" {
		t.Fatalf("got = %+v", got)
	}
}

// TestTranscriptScriptParsesRealShape roda o script python real sobre um HOME
// temporário com um .jsonl no formato do Claude Code, e valida a conversão em
// chunks tipados: mensagem do usuário → user; texto do assistente → assistant;
// tool_use → "Nome: comando"; tool_result → texto; thinking e caveat ignorados;
// ordem cronológica preservada.
func TestTranscriptScriptParsesRealShape(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando teste do script de transcript")
	}
	home := t.TempDir()
	sid := "aaaaaaaa-1111-2222-3333-444444444444"
	projDir := filepath.Join(home, ".claude", "projects", "encoded")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	lines := []string{
		// caveat sintético (deve ser ignorado)
		`{"type":"user","message":{"role":"user","content":"<local-command-caveat>ignore"}}`,
		// mensagem real do usuário
		`{"type":"user","message":{"role":"user","content":"conserta o build"}}`,
		// assistente: thinking (ignorado) + texto + tool_use
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"vou rodar os testes"},{"type":"tool_use","name":"Bash","input":{"command":"go test ./..."}}]}}`,
		// resultado da ferramenta (user-role com tool_result)
		`{"type":"user","message":{"role":"user","content":[{"tool_use_id":"x","type":"tool_result","content":"ok PASS"}]}}`,
	}
	if err := os.WriteFile(filepath.Join(projDir, sid+".jsonl"), []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	cmd := exec.Command(py, "-", sid)
	cmd.Env = append(os.Environ(), "HOME="+home)
	cmd.Stdin = strings.NewReader(transcriptScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar script: %v", err)
	}
	got, err := parseTranscript(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}

	want := []TranscriptChunk{
		{Kind: "user", Text: "conserta o build"},
		{Kind: "assistant", Text: "vou rodar os testes"},
		{Kind: "tool", Text: "Bash: go test ./..."},
		{Kind: "tool_result", Text: "ok PASS"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d chunks, quero %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("chunk[%d] = %+v, quero %+v", i, got[i], want[i])
		}
	}
}

// TestSSHTranscriptBuildsCommand: SSHTarget.Transcript monta o comando ssh e
// parseia a saída — troca o `ssh` local por um fake que ecoa uma fixture.
func TestSSHTranscriptBuildsCommand(t *testing.T) {
	dir := t.TempDir()
	fakeSSH := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ncat > /dev/null\n" +
		`printf '%s' '[{"kind":"user","text":"remoto"}]'` + "\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o755); err != nil {
		t.Fatalf("fake ssh: %v", err)
	}
	tgt := newSSHCommand("macmini", "dest", defaultRemoteClaudeCmd, fakeSSH, sshClaudeArgs)

	got, err := tgt.Transcript(context.Background(), "aaaaaaaa-1111-2222-3333-444444444444")
	if err != nil {
		t.Fatalf("Transcript: %v", err)
	}
	if len(got) != 1 || got[0].Kind != "user" || got[0].Text != "remoto" {
		t.Fatalf("got = %+v", got)
	}
}

// TestTranscriptScriptStripsANSIAndStdoutEcho: o histórico passa pelo mesmo
// crivo que o título. Eco de `<local-command-stdout>` não é mensagem do usuário
// e some; ANSI cru vira lixo ilegível no chat do app e sai do texto que fica.
// O tool_result também: ali a limpeza acontece ANTES do corte em 200, senão o
// corte cai no meio de uma sequência e sobra um pedaço solto visível.
func TestTranscriptScriptStripsANSIAndStdoutEcho(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando")
	}
	const sid = "dadadada-1111-2222-3333-444444444444"
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", "enc")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := strings.Join([]string{
		`{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to \u001b[1mOpus"}}`,
		`{"type":"user","message":{"role":"user","content":"roda a \u001b[0;33msuíte\u001b[0m"}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok\u001b[0m, rodando"}]}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\u001b[32mPASS\u001b[0m 375"}]}}`,
	}, "\n")
	if err := os.WriteFile(filepath.Join(dir, sid+".jsonl"), []byte(body), 0o644); err != nil {
		t.Fatalf("transcript: %v", err)
	}

	cmd := exec.Command(py, "-", sid)
	cmd.Env = append(os.Environ(), "HOME="+home)
	cmd.Stdin = strings.NewReader(transcriptScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar script: %v", err)
	}
	chunks, err := parseTranscript(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	quero := []TranscriptChunk{
		{Kind: "user", Text: "roda a suíte"},
		{Kind: "assistant", Text: "ok, rodando"},
		{Kind: "tool_result", Text: "PASS 375"},
	}
	if len(chunks) != len(quero) {
		t.Fatalf("chunks = %+v, quero %d (o eco de slash-command sai)", chunks, len(quero))
	}
	for i, q := range quero {
		if chunks[i].Kind != q.Kind || chunks[i].Text != q.Text {
			t.Errorf("chunk %d = {%q,%q}, quero {%q,%q}", i,
				chunks[i].Kind, chunks[i].Text, q.Kind, q.Text)
		}
	}
}
