package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/adapter/codex"
	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// silentLogger descarta os logs (o teste só quer o valor de retorno, não
// afirmar sobre o texto do log de aviso).
func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// Os testes de parseSSHTargets moraram aqui até a aba Máquinas: o parse virou
// internal/machine (com os mesmos casos, incluindo a defesa contra destino que
// parece opção do ssh) e é testado lá.

// TestBuildTargetsFallsBackToLocalMacbookWhenEmpty cobre a compatibilidade
// pedida na Fase 5: sem CUTUQUE_SSH_TARGETS, o comportamento é o de antes
// (LocalTarget "macbook").
func TestBuildTargetsFallsBackToLocalMacbookWhenEmpty(t *testing.T) {
	targets := buildTargets(nil)
	if len(targets) != 1 {
		t.Fatalf("targets = %v, quero só o macbook local", targets)
	}
	byAgent, ok := targets["macbook"]
	if !ok {
		t.Fatalf("targets = %v, quero a chave \"macbook\"", targets)
	}
	if _, isLocal := byAgent["claude-code"].(*claudecode.LocalTarget); !isLocal {
		t.Errorf("targets[\"macbook\"][claude-code] = %T, quero *claudecode.LocalTarget", byAgent["claude-code"])
	}
	if _, isCodex := byAgent["codex"].(*codex.LocalTarget); !isCodex {
		t.Errorf("targets[\"macbook\"][codex] = %T, quero *codex.LocalTarget", byAgent["codex"])
	}
}

// TestBuildTargetsUsesSSHTargetsWhenConfigured cobre a Fase 5: com a env var
// setada, os alvos viram SSHTarget (hub numa máquina, claude noutra via ssh) —
// nenhum LocalTarget implícito é adicionado.
func TestBuildTargetsUsesSSHTargetsWhenConfigured(t *testing.T) {
	targets := buildTargets([]machine.Machine{
		{Name: "macbook", Dest: "user@192.0.2.20", Port: 22, Source: machine.SourceEnv},
		{Name: "macmini", Dest: "remote-host", Port: 22, Source: machine.SourceEnv},
	})
	if len(targets) != 2 {
		t.Fatalf("targets = %v, quero 2 entradas", targets)
	}
	for _, name := range []string{"macbook", "macmini"} {
		byAgent, ok := targets[name]
		if !ok {
			t.Fatalf("targets = %v, quero a chave %q", targets, name)
		}
		tgt, ok := byAgent["claude-code"].(*claudecode.SSHTarget)
		if !ok {
			t.Errorf("targets[%q][claude-code] = %T, quero *claudecode.SSHTarget", name, byAgent["claude-code"])
			continue
		}
		if tgt.Name() != name {
			t.Errorf("targets[%q].Name() = %q", name, tgt.Name())
		}
		if _, isCodex := byAgent["codex"].(*codex.SSHTarget); !isCodex {
			t.Errorf("targets[%q][codex] = %T, quero *codex.SSHTarget", name, byAgent["codex"])
		}
	}
}

// --- openPostgresWithRetry -------------------------------------------------
//
// O retry existe por causa da queda de energia de 2026-07-28: no reboot o hub
// sobe junto com o Postgres e pode chegar primeiro, e a escolha do storage é
// feita uma vez só no boot. Os testes abaixo cobrem as duas pontas que importam
// — insistir quando é corrida de boot, desistir quando o Postgres está morto
// mesmo — sem nunca depender de um Postgres de verdade.

// shortRetryWaits encolhe o backoff para o teste rodar em milissegundos e
// restaura os valores de produção no fim.
func shortRetryWaits(t *testing.T) {
	t.Helper()
	first, max := pgRetryFirstWait, pgRetryMaxWait
	pgRetryFirstWait, pgRetryMaxWait = time.Millisecond, 2*time.Millisecond
	t.Cleanup(func() { pgRetryFirstWait, pgRetryMaxWait = first, max })
}

// TestOpenPostgresWithRetrySucceedsFirstTry: caminho feliz (Postgres já de pé no
// boot) não deve custar nenhuma espera nem tentativa extra.
func TestOpenPostgresWithRetrySucceedsFirstTry(t *testing.T) {
	shortRetryWaits(t)
	calls := 0
	got, err := openPostgresWithRetry(context.Background(), silentLogger(), "board",
		time.Now().Add(time.Minute),
		func(context.Context) (string, error) { calls++; return "pg", nil })
	if err != nil {
		t.Fatalf("openPostgresWithRetry() erro = %v, quero nil", err)
	}
	if got != "pg" || calls != 1 {
		t.Errorf("openPostgresWithRetry() = %q em %d tentativas, quero \"pg\" em 1", got, calls)
	}
}

// TestOpenPostgresWithRetryRetriesUntilPostgresAnswers é o caso do incidente: o
// connect falha algumas vezes enquanto o Postgres ainda sobe, e depois vai.
func TestOpenPostgresWithRetryRetriesUntilPostgresAnswers(t *testing.T) {
	shortRetryWaits(t)
	calls := 0
	got, err := openPostgresWithRetry(context.Background(), silentLogger(), "board",
		time.Now().Add(time.Minute),
		func(context.Context) (string, error) {
			if calls++; calls < 3 {
				return "", errors.New("connection refused")
			}
			return "pg", nil
		})
	if err != nil {
		t.Fatalf("openPostgresWithRetry() erro = %v, quero nil", err)
	}
	if got != "pg" || calls != 3 {
		t.Errorf("openPostgresWithRetry() = %q em %d tentativas, quero \"pg\" em 3", got, calls)
	}
}

// TestOpenPostgresWithRetryExpiredDeadlineTriesOnce trava o comportamento de dev
// (prazo já vencido): uma tentativa e cai no fallback, sem segurar o boot.
func TestOpenPostgresWithRetryExpiredDeadlineTriesOnce(t *testing.T) {
	shortRetryWaits(t)
	calls := 0
	want := errors.New("connection refused")
	_, err := openPostgresWithRetry(context.Background(), silentLogger(), "board",
		time.Now().Add(-time.Second),
		func(context.Context) (string, error) { calls++; return "", want })
	if !errors.Is(err, want) {
		t.Errorf("openPostgresWithRetry() erro = %v, quero %v", err, want)
	}
	if calls != 1 {
		t.Errorf("tentativas = %d, quero 1 (prazo vencido não pode segurar o boot)", calls)
	}
}

// TestOpenPostgresWithRetryGivesUpAfterDeadline: Postgres morto de verdade não
// pode prender o boot para sempre — desiste e devolve o último erro, que é o que
// leva o chamador ao fallback JSON.
func TestOpenPostgresWithRetryGivesUpAfterDeadline(t *testing.T) {
	shortRetryWaits(t)
	calls := 0
	want := errors.New("connection refused")
	done := make(chan error, 1)
	go func() {
		_, err := openPostgresWithRetry(context.Background(), silentLogger(), "board",
			time.Now().Add(20*time.Millisecond),
			func(context.Context) (string, error) { calls++; return "", want })
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, want) {
			t.Errorf("openPostgresWithRetry() erro = %v, quero %v", err, want)
		}
		if calls < 2 {
			t.Errorf("tentativas = %d, quero >= 2 (tinha prazo, devia ter insistido)", calls)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("openPostgresWithRetry() não respeitou o prazo; boot ficaria preso")
	}
}

// TestOpenPostgresWithRetryHonorsContextCancel: um SIGTERM no meio da espera tem
// que interromper o boot na hora, não depois do prazo inteiro.
func TestOpenPostgresWithRetryHonorsContextCancel(t *testing.T) {
	first, max := pgRetryFirstWait, pgRetryMaxWait
	pgRetryFirstWait, pgRetryMaxWait = time.Minute, time.Minute
	t.Cleanup(func() { pgRetryFirstWait, pgRetryMaxWait = first, max })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := openPostgresWithRetry(ctx, silentLogger(), "board",
			time.Now().Add(time.Hour),
			func(context.Context) (string, error) { return "", errors.New("connection refused") })
		done <- err
	}()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("openPostgresWithRetry() erro = %v, quero context.Canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("openPostgresWithRetry() ignorou o cancelamento do contexto")
	}
}
