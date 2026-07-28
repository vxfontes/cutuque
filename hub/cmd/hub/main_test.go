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
)

// silentLogger descarta os logs (o teste só quer o valor de retorno, não
// afirmar sobre o texto do log de aviso).
func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// TestParseSSHTargetsEmptyYieldsEmptyMap cobre o caso "sem env var": nenhum
// alvo SSH declarado.
func TestParseSSHTargetsEmptyYieldsEmptyMap(t *testing.T) {
	got := parseSSHTargets("", silentLogger())
	if len(got) != 0 {
		t.Errorf("parseSSHTargets(\"\") = %v, quero mapa vazio", got)
	}
}

// TestParseSSHTargetsParsesValidEntries cobre o formato documentado:
// "nome=destino,nome2=destino2".
func TestParseSSHTargetsParsesValidEntries(t *testing.T) {
	got := parseSSHTargets("macbook=user@192.0.2.20,macmini=remote-host", silentLogger())
	want := map[string]string{
		"macbook": "user@192.0.2.20",
		"macmini": "remote-host",
	}
	if len(got) != len(want) {
		t.Fatalf("parseSSHTargets = %v, quero %v", got, want)
	}
	for k, v := range want {
		if got[k].dest != v {
			t.Errorf("parseSSHTargets[%q].dest = %q, quero %q", k, got[k].dest, v)
		}
	}
}

// TestParseSSHTargetsThirdFieldIsRemoteCmd cobre o formato "nome=dest=claudecmd":
// o 3º campo vira o caminho absoluto do claude remoto.
func TestParseSSHTargetsThirdFieldIsRemoteCmd(t *testing.T) {
	got := parseSSHTargets("macbook=example@192.0.2.20=/Users/example/.local/bin/claude", silentLogger())
	d, ok := got["macbook"]
	if !ok {
		t.Fatalf("parseSSHTargets = %v, quero a chave macbook", got)
	}
	if d.dest != "example@192.0.2.20" {
		t.Errorf("dest = %q", d.dest)
	}
	if d.remoteCmd != "/Users/example/.local/bin/claude" {
		t.Errorf("remoteCmd = %q, quero o caminho absoluto", d.remoteCmd)
	}
}

// TestParseSSHTargetsRejectsDashDest cobre a defesa contra injeção: um destino
// começando com "-" (ex.: -oProxyCommand=...) é ignorado.
func TestParseSSHTargetsRejectsDashDest(t *testing.T) {
	got := parseSSHTargets("evil=-oProxyCommand=touch /tmp/pwned,ok=user@host", silentLogger())
	if _, bad := got["evil"]; bad {
		t.Errorf("destino com '-' não deveria ser aceito: %v", got)
	}
	if got["ok"].dest != "user@host" {
		t.Errorf("entrada válida ao redor deveria sobreviver: %v", got)
	}
}

// TestParseSSHTargetsIgnoresMalformedEntries cobre o parse defensivo: entradas
// sem "=", com nome ou destino vazio são ignoradas — não derrubam o parse das
// entradas válidas ao redor.
func TestParseSSHTargetsIgnoresMalformedEntries(t *testing.T) {
	raw := "macbook=user@host, sem-igual , =destino-sem-nome, nome-sem-destino=, macmini=host2"
	got := parseSSHTargets(raw, silentLogger())
	want := map[string]string{
		"macbook": "user@host",
		"macmini": "host2",
	}
	if len(got) != len(want) {
		t.Fatalf("parseSSHTargets(%q) = %v, quero só as entradas válidas %v", raw, got, want)
	}
	for k, v := range want {
		if got[k].dest != v {
			t.Errorf("parseSSHTargets[%q].dest = %q, quero %q", k, got[k].dest, v)
		}
	}
}

// TestParseSSHTargetsTrimsWhitespace garante espaços ao redor de nome/destino
// não quebram o parse (formato amigável para copiar/colar em .env).
func TestParseSSHTargetsTrimsWhitespace(t *testing.T) {
	got := parseSSHTargets(" macbook = user@host , macmini = host2 ", silentLogger())
	if got["macbook"].dest != "user@host" || got["macmini"].dest != "host2" {
		t.Errorf("parseSSHTargets com espaços = %v", got)
	}
}

// TestBuildTargetsFallsBackToLocalMacbookWhenEmpty cobre a compatibilidade
// pedida na Fase 5: sem CUTUQUE_SSH_TARGETS, o comportamento é o de antes
// (LocalTarget "macbook").
func TestBuildTargetsFallsBackToLocalMacbookWhenEmpty(t *testing.T) {
	targets := buildTargets("", silentLogger())
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
	targets := buildTargets("macbook=user@192.0.2.20,macmini=remote-host", silentLogger())
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
