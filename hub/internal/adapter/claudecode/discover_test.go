package claudecode

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestParseDiscoveredValid cobre o caminho feliz: JSON da lista → []Discovered.
func TestParseDiscoveredValid(t *testing.T) {
	out := []byte(`[{"id":"a1","cwd":"/Users/example/proj","title":"arruma o build","modified":1720000000},
	{"id":"b2","cwd":"/tmp","title":"oi","modified":1719999999}]`)
	got, err := parseDiscovered(out)
	if err != nil {
		t.Fatalf("parseDiscovered: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, quero 2", len(got))
	}
	if got[0].ID != "a1" || got[0].Cwd != "/Users/example/proj" || got[0].Title != "arruma o build" || got[0].Modified != 1720000000 {
		t.Errorf("primeiro item errado: %+v", got[0])
	}
}

// TestParseDiscoveredEmpty cobre saída vazia (máquina sem sessões) → nil, sem erro.
func TestParseDiscoveredEmpty(t *testing.T) {
	for _, in := range []string{"", "   ", "\n"} {
		got, err := parseDiscovered([]byte(in))
		if err != nil {
			t.Errorf("parseDiscovered(%q): erro inesperado %v", in, err)
		}
		if got != nil {
			t.Errorf("parseDiscovered(%q) = %v, quero nil", in, got)
		}
	}
}

// TestParseDiscoveredMalformed garante que JSON corrompido vira erro (não panic
// nem lista silenciosamente vazia).
func TestParseDiscoveredMalformed(t *testing.T) {
	if _, err := parseDiscovered([]byte(`{não é json`)); err == nil {
		t.Error("parseDiscovered de JSON inválido devia falhar")
	}
}

// TestLocalDiscoverViaFakeProgram troca o `python3` real por um `cat` sobre uma
// fixture: prova que Discover envia o script pelo stdin e faz parse da saída.
// (o `cat` ignora o script no stdin e ecoa a fixture — o que importa aqui é o
// parse da saída do processo, não o script em si).
func TestLocalDiscoverViaFakeProgram(t *testing.T) {
	dir := t.TempDir()
	fixture := filepath.Join(dir, "out.json")
	if err := os.WriteFile(fixture, []byte(`[{"id":"sess-1","cwd":"/x","title":"t","modified":1}]`), 0o644); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// runDiscover roda cmd.Output(); usamos `cat <fixture>` como programa fake.
	got, err := runDiscover(exec.Command("cat", fixture))
	if err != nil {
		t.Fatalf("runDiscover: %v", err)
	}
	if len(got) != 1 || got[0].ID != "sess-1" {
		t.Fatalf("got = %+v, quero [sess-1]", got)
	}
}

// TestSSHDiscoverBuildsCommand prova que SSHTarget.Discover monta o comando ssh
// com as opções-base e o `python3 -` remoto, e faz parse da saída — trocando o
// binário `ssh` local por um script fake que ecoa uma fixture.
func TestSSHDiscoverBuildsCommand(t *testing.T) {
	dir := t.TempDir()
	// ssh falso: ignora seus args, lê e descarta o stdin (o script) e imprime a
	// lista JSON — como um python3 remoto bem-comportado faria.
	fakeSSH := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ncat > /dev/null\n" +
		`printf '%s' '[{"id":"remote-1","cwd":"/r","title":"rt","modified":9}]'` + "\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o755); err != nil {
		t.Fatalf("fake ssh: %v", err)
	}
	tgt := newSSHCommand("macmini", "dest", defaultRemoteClaudeCmd, fakeSSH, sshClaudeArgs)

	got, err := tgt.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(got) != 1 || got[0].ID != "remote-1" || got[0].Cwd != "/r" {
		t.Fatalf("got = %+v, quero [remote-1]", got)
	}
}

// TestDiscoverScriptSkipsSyntheticTitles é um teste de comportamento do script
// python de descoberta: mensagens sintéticas de slash-command (caveat/command)
// não viram título, e espaços/quebras de linha são normalizados. Roda o script
// real com um python3 do sistema sobre um HOME temporário com fixtures .jsonl.
func TestDiscoverScriptSkipsSyntheticTitles(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando teste do script de descoberta")
	}
	home := t.TempDir()
	projDir := filepath.Join(home, ".claude", "projects", "encoded")
	if err := os.MkdirAll(projDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	// Sessão A: 1ª mensagem é caveat sintético, 2ª é a real (multi-linha).
	sessA := strings.Join([]string{
		`{"cwd":"/Users/example/proj","type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: ignore isso"}}`,
		`{"type":"user","message":{"role":"user","content":"minha   pergunta\nde verdade"}}`,
	}, "\n")
	if err := os.WriteFile(filepath.Join(projDir, "aaaaaaaa-0000-0000-0000-000000000001.jsonl"), []byte(sessA), 0o644); err != nil {
		t.Fatalf("write A: %v", err)
	}
	// Sessão B: só mensagens sintéticas → sem título → descartada.
	sessB := `{"cwd":"/x","type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}`
	if err := os.WriteFile(filepath.Join(projDir, "bbbbbbbb-0000-0000-0000-000000000002.jsonl"), []byte(sessB), 0o644); err != nil {
		t.Fatalf("write B: %v", err)
	}

	cmd := exec.Command(py, "-")
	cmd.Env = append(os.Environ(), "HOME="+home)
	cmd.Stdin = strings.NewReader(discoverScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("rodar script: %v", err)
	}
	list, err := parseDiscovered(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("quero 1 sessão (a sintética descartada), got %d: %+v", len(list), list)
	}
	if list[0].Title != "minha pergunta de verdade" {
		t.Errorf("título = %q, quero espaços normalizados e sem caveat", list[0].Title)
	}
}
