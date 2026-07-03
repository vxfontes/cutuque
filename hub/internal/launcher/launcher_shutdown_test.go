package launcher

import (
	"bufio"
	"context"
	"io"
	"testing"
	"time"
)

// liveUntilClosedScript imita um processo real de vida longa: emite o
// session_started e só termina quando o stdin fecha de verdade (EOF),
// exatamente o cenário que Shutdown precisa encerrar.
func liveUntilClosedScript(stdout io.Writer, stdin *bufio.Reader, _ chan<- string) {
	_, _ = stdin.ReadString('\n') // prompt inicial
	_, _ = io.WriteString(stdout, initLine+"\n")
	_, _ = io.Copy(io.Discard, stdin) // só retorna quando o stdin fechar (EOF)
}

// TestShutdownClosesAllHandlesAndReturns cobre a tarefa 2 da Fase 5: Shutdown
// fecha toda sessão viva e retorna sem travar (o processo real fica "vivo" até
// o Close acontecer — se Shutdown não fechasse o Handle, o teste travaria no
// timeout abaixo).
func TestShutdownClosesAllHandlesAndReturns(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: liveUntilClosedScript, captured: make(chan string, 1)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "tarefa", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		_, ok := reg.Get(sid)
		return ok
	})

	done := make(chan struct{})
	go func() {
		l.Shutdown()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Shutdown travou esperando as sessões encerrarem")
	}

	// Após Shutdown, a porta está fechada: SendText tenta retomar (sem handle
	// vivo) mas o resume é recusado com ErrShuttingDown (não spawna novo processo).
	if err := l.SendText(sid, "oi"); err != ErrShuttingDown {
		t.Errorf("SendText após Shutdown = %v, quero ErrShuttingDown", err)
	}

	// Chamada tardia é segura (idempotente o suficiente: não deve travar nem
	// pânico ao iterar mapas já vazios).
	done2 := make(chan struct{})
	go func() {
		l.Shutdown()
		close(done2)
	}()
	select {
	case <-done2:
	case <-time.After(2 * time.Second):
		t.Fatal("segunda chamada a Shutdown travou")
	}
}

// TestShutdownWithNoSessionsReturnsImmediately garante que Shutdown num
// Launcher sem nenhuma sessão viva não trava (caminho trivial, mas evita
// regressão de um wg.Wait() esperando algo que nunca foi Add()).
func TestShutdownWithNoSessionsReturnsImmediately(t *testing.T) {
	l, _ := newTestLauncher(nil)

	done := make(chan struct{})
	go func() {
		l.Shutdown()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Shutdown sem sessões travou")
	}
}
