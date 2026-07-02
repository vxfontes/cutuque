package claudecode

import (
	"context"
	"io"
	"strings"
	"sync"
	"testing"
)

// TestHandleCloseConcurrentIsSafe cobre a race real do review F3 (achado #1):
// Close chamado ao mesmo tempo pelo timeout do Launch e pelo fim natural do
// Runner não pode disparar dois cmd.Wait() concorrentes (data race na stdlib).
// Usa o processo REAL (cat espera EOF do stdin) — é o cenário que os fakes de
// io.Pipe não exercitam. Roda sob -race.
func TestHandleCloseConcurrentIsSafe(t *testing.T) {
	tgt := newLocalCommand("m", "cat", func() []string { return nil })
	h, err := tgt.Start(context.Background())
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	const goroutines = 4
	var wg sync.WaitGroup
	for range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = h.Close() // idempotente: só o primeiro executa o Wait
		}()
	}
	wg.Wait()

	// Chamada tardia também é segura e devolve o mesmo resultado.
	_ = h.Close()
}

// TestLocalTargetDoesNotLeakHubEnv cobre o SEC-006 do review F3: o processo do
// agente NÃO herda o ambiente do hub (CUTUQUE_TOKEN etc.) — só a allowlist.
func TestLocalTargetDoesNotLeakHubEnv(t *testing.T) {
	t.Setenv("CUTUQUE_TOKEN", "super-secreto-sentinela")
	t.Setenv("CUTUQUE_TEST_SENTINELA", "vazou")

	tgt := newLocalCommand("m", "env", func() []string { return nil })
	h, err := tgt.Start(context.Background())
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	out, err := io.ReadAll(h.Stdout)
	if err != nil {
		t.Fatalf("lendo stdout: %v", err)
	}
	_ = h.Close()

	env := string(out)
	if strings.Contains(env, "super-secreto-sentinela") || strings.Contains(env, "CUTUQUE_TEST_SENTINELA") {
		t.Fatalf("ambiente do hub vazou para o processo do agente:\n%s", env)
	}
	if !strings.Contains(env, "HOME=") {
		t.Errorf("HOME deveria estar na allowlist do filho (claude precisa dela):\n%s", env)
	}
}
