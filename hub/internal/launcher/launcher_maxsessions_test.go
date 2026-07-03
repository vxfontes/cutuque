package launcher

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// startedOnlyScript emite só o session_started (init) e depois fica "viva"
// copiando o stdin para o vazio até o Handle ser fechado — imita um processo
// real que segue rodando até receber EOF (Close), o suficiente para contar
// como sessão viva no teste de teto sem terminar sozinha.
func startedOnlyScript(sessionID string) func(stdout io.Writer, stdin *bufio.Reader, _ chan<- string) {
	return func(stdout io.Writer, stdin *bufio.Reader, _ chan<- string) {
		_, _ = stdin.ReadString('\n') // prompt inicial
		_, _ = io.WriteString(stdout, `{"type":"system","subtype":"init","session_id":"`+sessionID+`"}`+"\n")
		_, _ = io.Copy(io.Discard, stdin) // segue "viva" até o Close fechar o stdin
	}
}

// fixtureTargets monta n alvos ("m0".."m(n-1)"), cada um com sua própria
// sessão ("s0".."s(n-1)") — necessário porque cada Launch precisa de um
// session_id distinto para não colidir no Registry.
func fixtureTargets(n int) map[string]claudecode.Target {
	targets := make(map[string]claudecode.Target, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("m%d", i)
		sessionID := fmt.Sprintf("s%d", i)
		targets[name] = &scriptTarget{name: name, run: startedOnlyScript(sessionID), captured: make(chan string, 1)}
	}
	return targets
}

// TestNewLauncherDefaultsMaxSessionsTo20 cobre o default aplicado por New
// quando cmd/hub não chama SetMaxSessions (dev, ou config.MaxSessions == 0).
func TestNewLauncherDefaultsMaxSessionsTo20(t *testing.T) {
	l, _ := newTestLauncher(nil)
	if l.maxSessions != defaultMaxSessions {
		t.Errorf("maxSessions = %d, quero default %d", l.maxSessions, defaultMaxSessions)
	}
}

// TestSetMaxSessionsIgnoresNonPositive cobre a validação de SetMaxSessions:
// valores <= 0 são ignorados, mantendo o teto anterior (mesma regra do
// Notifier.SetRenudgeInterval).
func TestSetMaxSessionsIgnoresNonPositive(t *testing.T) {
	l, _ := newTestLauncher(nil)
	l.SetMaxSessions(5)
	l.SetMaxSessions(0)
	l.SetMaxSessions(-1)
	if l.maxSessions != 5 {
		t.Errorf("maxSessions = %d, quero 5 (0/-1 deveriam ser ignorados)", l.maxSessions)
	}
}

// TestLaunchAcceptsUpToMaxSessionsThenRejects é o teste central do SEC-007:
// até o teto, Launch aceita normalmente; a sessão seguinte é rejeitada com
// ErrTooManySessions.
func TestLaunchAcceptsUpToMaxSessionsThenRejects(t *testing.T) {
	const max = 2

	reg := registry.New()
	eng := engine.New(reg)
	l := New(eng, reg, fixtureTargets(max+1))
	l.SetMaxSessions(max)
	defer l.Shutdown()

	for i := 0; i < max; i++ {
		machine := fmt.Sprintf("m%d", i)
		s, err := l.Launch(context.Background(), machine, agentClaudeCode, "tarefa")
		if err != nil {
			t.Fatalf("Launch %d (%s): %v", i, machine, err)
		}
		if s.Machine != machine {
			t.Errorf("Launch %d: session.Machine = %q, quero %q", i, s.Machine, machine)
		}
	}

	overflowMachine := fmt.Sprintf("m%d", max)
	if _, err := l.Launch(context.Background(), overflowMachine, agentClaudeCode, "excedente"); err != ErrTooManySessions {
		t.Fatalf("Launch acima do teto: err = %v, quero ErrTooManySessions", err)
	}
}
