package opencode

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// requirePython3 pula o teste se não houver python3 (a descoberta/transcript do
// OpenCode dependem dele, como o adapter do Codex).
func requirePython3(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 indisponível; pulando o teste de disco do OpenCode")
	}
}

// writeJSON grava v como JSON em path, criando os diretórios.
func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

// fakeStorage monta um storage do OpenCode (uma sessão com 1 msg do usuário e 1
// do assistente + 1 tool) sob home, e devolve o sid. Espelha o layout real do
// opencode 1.x (session/<proj>/ses_*.json, message/<sid>/*, part/<msgID>/*).
func fakeStorage(t *testing.T, home string) string {
	t.Helper()
	base := filepath.Join(home, ".local", "share", "opencode", "storage")
	sid := "ses_testsession00000001"
	userMsg, asstMsg := "msg_user0000001", "msg_asst0000001"

	writeJSON(t, filepath.Join(base, "session", "proj1", sid+".json"), map[string]any{
		"id": sid, "directory": "/Users/tester/proj", "title": "Sessão de teste",
		"time": map[string]any{"created": 1770000000000, "updated": 1770000009000},
	})
	writeJSON(t, filepath.Join(base, "message", sid, userMsg+".json"), map[string]any{
		"id": userMsg, "role": "user", "time": map[string]any{"created": 1770000001000},
	})
	writeJSON(t, filepath.Join(base, "message", sid, asstMsg+".json"), map[string]any{
		"id": asstMsg, "role": "assistant", "time": map[string]any{"created": 1770000002000},
	})
	writeJSON(t, filepath.Join(base, "part", userMsg, "prt_u1.json"), map[string]any{
		"id": "prt_u1", "type": "text", "text": "liste os arquivos", "time": map[string]any{"start": 1770000001000},
	})
	writeJSON(t, filepath.Join(base, "part", asstMsg, "prt_a1.json"), map[string]any{
		"id": "prt_a1", "type": "text", "text": "claro, já listo", "time": map[string]any{"start": 1770000002000},
	})
	writeJSON(t, filepath.Join(base, "part", asstMsg, "prt_a2.json"), map[string]any{
		"id": "prt_a2", "type": "tool", "tool": "bash",
		"state": map[string]any{"status": "completed", "input": map[string]any{"command": "ls"}, "output": "arquivo.txt"},
		"time":  map[string]any{"start": 1770000003000},
	})
	// Ruído que deve ser ignorado (reasoning) e uma sessão sem título (descartada).
	writeJSON(t, filepath.Join(base, "part", asstMsg, "prt_a0.json"), map[string]any{
		"id": "prt_a0", "type": "reasoning", "text": "pensando…", "time": map[string]any{"start": 1770000001500},
	})
	writeJSON(t, filepath.Join(base, "session", "proj1", "ses_semtitulo0000001.json"), map[string]any{
		"id": "ses_semtitulo0000001", "directory": "/x", "title": "",
		"time": map[string]any{"updated": 1770000000000},
	})
	return sid
}

func TestDiscoverLocalLeSessoesDoStorage(t *testing.T) {
	requirePython3(t)
	home := t.TempDir()
	sid := fakeStorage(t, home)
	t.Setenv("HOME", home)

	list, err := NewLocalTarget("local").Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	// Só a sessão com título entra (a sem título é descartada).
	if len(list) != 1 {
		t.Fatalf("len(list) = %d, quero 1: %+v", len(list), list)
	}
	d := list[0]
	if d.ID != sid {
		t.Errorf("ID = %q, quero %q", d.ID, sid)
	}
	if d.Cwd != "/Users/tester/proj" {
		t.Errorf("Cwd = %q", d.Cwd)
	}
	if d.Title != "Sessão de teste" {
		t.Errorf("Title = %q", d.Title)
	}
	if d.Count != 1 {
		t.Errorf("Count = %d, quero 1 (mensagens do usuário)", d.Count)
	}
	if d.Last != "liste os arquivos" {
		t.Errorf("Last = %q", d.Last)
	}
	if d.Modified != 1770000009 {
		t.Errorf("Modified = %d, quero 1770000009 (time.updated em segundos)", d.Modified)
	}
}
