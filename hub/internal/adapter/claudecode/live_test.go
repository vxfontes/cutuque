package claudecode

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestSSHLiveBuildsCommand: SSHTarget.Live monta o comando ssh e parseia a saída
// no mesmo shape do discover — troca o `ssh` por um fake que ecoa uma fixture.
func TestSSHLiveBuildsCommand(t *testing.T) {
	dir := t.TempDir()
	fakeSSH := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ncat > /dev/null\n" +
		`printf '%s' '[{"id":"live-1","cwd":"/r","title":"rodando","last":"oi","count":3,"modified":9}]'` + "\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o755); err != nil {
		t.Fatalf("fake ssh: %v", err)
	}
	tgt := newSSHCommand("macmini", "dest", defaultRemoteClaudeCmd, fakeSSH, sshClaudeArgs)

	got, err := tgt.Live(context.Background())
	if err != nil {
		t.Fatalf("Live: %v", err)
	}
	if len(got) != 1 || got[0].ID != "live-1" || got[0].Cwd != "/r" {
		t.Fatalf("got = %+v, quero [live-1]", got)
	}
}

// TestLiveScriptRunsAndEmitsJSON garante que o liveScript é python válido e
// sempre emite uma lista JSON (mesmo sem sessões vivas), sobre um HOME vazio —
// não valida a detecção de processos (depende do SO), só o contrato de saída.
func TestLiveScriptRunsAndEmitsJSON(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando")
	}
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude", "projects"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	cmd := exec.Command(py, "-")
	cmd.Env = append(os.Environ(), "HOME="+home)
	cmd.Stdin = strings.NewReader(liveScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("liveScript falhou: %v", err)
	}
	var list []map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &list); err != nil {
		t.Fatalf("liveScript não emitiu JSON de lista: %v (out=%q)", err, out)
	}
}
