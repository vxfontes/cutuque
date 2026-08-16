package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
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

// TestMachinesForRegistryEspelhaOFallbackLocal: /machines não pode listar
// vazio num hub que tem alvo. Sem CUTUQUE_SSH_TARGETS o buildTargets cria o
// LocalTarget "macbook", e a aba Máquinas precisa enxergar o mesmo.
func TestMachinesForRegistryEspelhaOFallbackLocal(t *testing.T) {
	got := machinesForRegistry(nil)
	if len(got) != 1 || got[0].Name != "macbook" {
		t.Fatalf("sem env var, quero só o macbook local, veio %+v", got)
	}
	if got[0].Source != machine.SourceLocal {
		t.Errorf("a máquina implícita deve ser Source=local, veio %q", got[0].Source)
	}
}

// TestMachinesForRegistryNaoMexeQuandoHaEnv: com alvos declarados, o fallback
// não entra — o macbook deixa de ser "grátis" (Fase 5).
func TestMachinesForRegistryNaoMexeQuandoHaEnv(t *testing.T) {
	in := []machine.Machine{{Name: "macmini", Dest: "vx@host", Port: 22, Source: machine.SourceEnv}}
	got := machinesForRegistry(in)
	if len(got) != 1 || got[0].Name != "macmini" {
		t.Errorf("com env var, quero as máquinas do env, veio %+v", got)
	}
}

// TestBuildTargetsFallsBackToLocalMacbookWhenEmpty cobre a compatibilidade
// pedida na Fase 5: sem CUTUQUE_SSH_TARGETS, o comportamento é o de antes
// (LocalTarget "macbook").
func TestBuildTargetsFallsBackToLocalMacbookWhenEmpty(t *testing.T) {
	targets := buildTargets(nil, false)
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

// TestBuildTargetsLocalShellSoTrocaOClaudeCode [16/08/2026]: com
// CUTUQUE_LOCAL_SHELL ligado, o alvo do claude-code vira o que abre terminal
// dentro do container (caixa pública do review da App Store). Só ele: é o
// claude-code que o Launcher.anyTarget escolhe deterministicamente, e trocar os
// outros seria mexer onde não precisa.
func TestBuildTargetsLocalShellSoTrocaOClaudeCode(t *testing.T) {
	byAgent := buildTargets(nil, true)["macbook"]

	tgt, ok := byAgent["claude-code"].(*claudecode.LocalShellTarget)
	if !ok {
		t.Fatalf("targets[\"macbook\"][claude-code] = %T, quero *claudecode.LocalShellTarget", byAgent["claude-code"])
	}
	if tgt.Name() != "macbook" {
		t.Errorf("Name() = %q, quero \"macbook\" — se mudar, /machines e o Launcher deixam de se encontrar", tgt.Name())
	}
	if _, isCodex := byAgent["codex"].(*codex.LocalTarget); !isCodex {
		t.Errorf("targets[\"macbook\"][codex] = %T, quero o *codex.LocalTarget de sempre", byAgent["codex"])
	}
}

// TestBuildTargetsLocalShellNaoMexeQuandoHaMaquinas: a chave só governa o ramo
// do fallback. Com CUTUQUE_SSH_TARGETS configurado os alvos são SSHTargets, que
// já têm shell de verdade — ligar a env aí não pode transformar máquina remota
// em shell de container.
func TestBuildTargetsLocalShellNaoMexeQuandoHaMaquinas(t *testing.T) {
	targets := buildTargets([]machine.Machine{
		{Name: "macbook", Dest: "user@192.0.2.20", Port: 22, Source: machine.SourceEnv},
	}, true)

	if _, isSSH := targets["macbook"]["claude-code"].(*claudecode.SSHTarget); !isSSH {
		t.Errorf("targets[\"macbook\"][claude-code] = %T, quero *claudecode.SSHTarget mesmo com localShell ligado", targets["macbook"]["claude-code"])
	}
}

// TestEnvLigada: estas chaves afrouxam coisa (abrem um terminal dentro do
// container, tiram rotas do mux), então o default tem que ser "não" e o "sim"
// tem que ser explícito. Em especial env var PRESENTE porém vazia (o jeito
// clássico de um compose "desligar" algo) não pode ligar nada.
func TestEnvLigada(t *testing.T) {
	const chave = "CUTUQUE_TESTE_LIGADA"
	casos := map[string]bool{
		"1": true, "true": true, "yes": true, "on": true, "sim": true,
		"TRUE": true, " sim ": true, // maiúscula e espaço sobrando não deveriam decidir nada
		"":       false,
		"0":      false,
		"false":  false,
		"no":     false,
		"nao":    false,
		"talvez": false, // valor sem sentido → desligado, nunca "presente logo ligado"
	}
	for valor, quero := range casos {
		t.Run("valor="+valor, func(t *testing.T) {
			t.Setenv(chave, valor)
			if got := envLigada(chave); got != quero {
				t.Errorf("envLigada() com %q = %v, quero %v", valor, got, quero)
			}
		})
	}

	t.Run("env ausente", func(t *testing.T) {
		t.Setenv(chave, "irrelevante") // só para o cleanup restaurar
		os.Unsetenv(chave)
		if envLigada(chave) {
			t.Error("sem a env var a chave ligou sozinha")
		}
	})
}

// TestCadaChaveLeASuaPropriaEnv guarda contra o erro de copiar-colar que o
// envLigada compartilhado convida: duas funções de uma linha, quase idênticas,
// e uma delas lendo o nome da outra. Aí ligar o modo público abriria um shell,
// ou ligar o shell derrubaria o dashboard — e nenhum teste de valor pegaria.
func TestCadaChaveLeASuaPropriaEnv(t *testing.T) {
	t.Setenv("CUTUQUE_LOCAL_SHELL", "1")
	t.Setenv("CUTUQUE_PUBLIC", "")
	if !localShellLigado() {
		t.Error("CUTUQUE_LOCAL_SHELL=1 não ligou o terminal local")
	}
	if publicoLigado() {
		t.Error("o modo público ligou lendo a env do terminal local")
	}

	t.Setenv("CUTUQUE_LOCAL_SHELL", "")
	t.Setenv("CUTUQUE_PUBLIC", "1")
	if !publicoLigado() {
		t.Error("CUTUQUE_PUBLIC=1 não ligou o modo público")
	}
	if localShellLigado() {
		t.Error("o terminal local ligou lendo a env do modo público")
	}
}

// TestEnvDesligada cobre o "não" EXPLÍCITO. O que importa aqui é a diferença que
// o !envLigada não sabe fazer: env ausente e env escrita "0" são as duas
// "desligada" pro envLigada, mas só a segunda é uma decisão de alguém.
func TestEnvDesligada(t *testing.T) {
	const chave = "CUTUQUE_TESTE_DESLIGADA"
	casos := map[string]bool{
		"0": true, "false": true, "no": true, "off": true, "nao": true, "não": true,
		"FALSE": true, " off ": true, // maiúscula e espaço sobrando não decidem nada
		"":       false, // vazio não é "não", é ausência
		"1":      false,
		"sim":    false,
		"talvez": false, // valor sem sentido não vira "não" — só o "não" explícito conta
	}
	for valor, quero := range casos {
		t.Run("valor="+valor, func(t *testing.T) {
			t.Setenv(chave, valor)
			if got := envDesligada(chave); got != quero {
				t.Errorf("envDesligada() com %q = %v, quero %v", valor, got, quero)
			}
		})
	}

	t.Run("env ausente não é não explícito", func(t *testing.T) {
		t.Setenv(chave, "irrelevante") // só para o cleanup restaurar
		os.Unsetenv(chave)
		if envDesligada(chave) {
			t.Error("env ausente virou 'não' explícito — some a diferença que justifica a função")
		}
	})
}

// TestAccessLogLigado guarda a regra do log de acesso: ele acompanha o modo
// público por implicação (caixa exposta sem log é caixa cega — o Render Hobby não
// dá HTTP request logs), mas um CUTUQUE_ACCESS_LOG=0 escrito à mão ganha da
// implicação, sem precisar desligar o modo público junto.
func TestAccessLogLigado(t *testing.T) {
	casos := []struct {
		nome, accessLog, publico string
		quero                    bool
	}{
		{"nada ligado", "", "", false},
		{"ligado à mão", "1", "", true},
		{"público liga sozinho", "", "1", true},
		{"não explícito ganha do público", "0", "1", false},
		{"não explícito com público desligado", "0", "", false},
		{"valor sem sentido não desliga o público", "talvez", "1", true},
		{"valor sem sentido sozinho não liga", "talvez", "", false},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			t.Setenv("CUTUQUE_ACCESS_LOG", c.accessLog)
			t.Setenv("CUTUQUE_PUBLIC", c.publico)
			if got := accessLogLigado(); got != c.quero {
				t.Errorf("accessLogLigado() com ACCESS_LOG=%q PUBLIC=%q = %v, quero %v",
					c.accessLog, c.publico, got, c.quero)
			}
		})
	}
}

// O log de acesso não pode ser um atalho pro terminal local: são chaves de risco
// bem diferente (uma imprime metadado, a outra abre shell dentro do container).
func TestAccessLogNaoLigaOTerminalLocal(t *testing.T) {
	t.Setenv("CUTUQUE_ACCESS_LOG", "1")
	t.Setenv("CUTUQUE_PUBLIC", "")
	t.Setenv("CUTUQUE_LOCAL_SHELL", "")

	if !accessLogLigado() {
		t.Fatal("CUTUQUE_ACCESS_LOG=1 não ligou o log")
	}
	if localShellLigado() {
		t.Error("ligar o log de acesso abriu o terminal local")
	}
	if publicoLigado() {
		t.Error("ligar o log de acesso ligou o modo público")
	}
}

// TestBuildTargetsUsesSSHTargetsWhenConfigured cobre a Fase 5: com a env var
// setada, os alvos viram SSHTarget (hub numa máquina, claude noutra via ssh) —
// nenhum LocalTarget implícito é adicionado.
func TestBuildTargetsUsesSSHTargetsWhenConfigured(t *testing.T) {
	targets := buildTargets([]machine.Machine{
		{Name: "macbook", Dest: "user@192.0.2.20", Port: 22, Source: machine.SourceEnv},
		{Name: "macmini", Dest: "remote-host", Port: 22, Source: machine.SourceEnv},
	}, false)
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
