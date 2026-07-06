package claudecode

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// TestHandleCloseConcurrentIsSafe cobre a race real do review F3 (achado #1):
// Close chamado ao mesmo tempo pelo timeout do Launch e pelo fim natural do
// Runner não pode disparar dois cmd.Wait() concorrentes (data race na stdlib).
// Usa o processo REAL (cat espera EOF do stdin) — é o cenário que os fakes de
// io.Pipe não exercitam. Roda sob -race.
func TestHandleCloseConcurrentIsSafe(t *testing.T) {
	tgt := newLocalCommand("m", "cat", func(string) []string { return nil })
	h, err := tgt.Start(context.Background(), "", "", "", "", "")
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

	tgt := newLocalCommand("m", "env", func(string) []string { return nil })
	h, err := tgt.Start(context.Background(), "", "", "", "", "")
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

// TestLocalTargetSetsCmdDirFromCwd cobre o campo cwd novo: quando != "", o
// processo do agente roda com esse diretório de trabalho. Resolve symlinks dos
// dois lados (no macOS /tmp é um symlink pra /private/tmp, e o `pwd` real
// devolve o caminho físico) para comparar o diretório de fato, não a grafia.
func TestLocalTargetSetsCmdDirFromCwd(t *testing.T) {
	dir := t.TempDir()
	wantDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatalf("EvalSymlinks: %v", err)
	}

	tgt := newLocalCommand("m", "pwd", func(string) []string { return nil })
	h, startErr := tgt.Start(context.Background(), "", dir, "", "", "")
	if startErr != nil {
		t.Fatalf("Start: %v", startErr)
	}
	out, err := io.ReadAll(h.Stdout)
	if err != nil {
		t.Fatalf("lendo stdout: %v", err)
	}
	_ = h.Close()

	got := strings.TrimSpace(string(out))
	if got != wantDir {
		t.Errorf("pwd = %q, quero %q (cwd propagado)", got, wantDir)
	}
}

// TestLocalTargetEmptyCwdUsesDefault garante que cwd vazio não mexe em
// cmd.Dir (mantém o diretório default do processo do hub — hoje é "home").
func TestLocalTargetEmptyCwdUsesDefault(t *testing.T) {
	tgt := newLocalCommand("m", "pwd", func(string) []string { return nil })
	h, err := tgt.Start(context.Background(), "", "", "", "", "")
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	out, err := io.ReadAll(h.Stdout)
	if err != nil {
		t.Fatalf("lendo stdout: %v", err)
	}
	_ = h.Close()

	if strings.TrimSpace(string(out)) == "" {
		t.Errorf("pwd não produziu saída")
	}
}

// --- SSHTarget ---------------------------------------------------------

// TestNewSSHTargetDefaults confirma o construtor real (não mais o stub): nome,
// destino e comando remoto default sensato ("claude", assume-se no PATH).
func TestNewSSHTargetDefaults(t *testing.T) {
	tgt := NewSSHTarget("macmini", "remote-host")
	if tgt.Name() != "macmini" {
		t.Errorf("Name() = %q, quero \"macmini\"", tgt.Name())
	}
	if tgt.dest != "remote-host" {
		t.Errorf("dest = %q, quero \"remote-host\"", tgt.dest)
	}
	if tgt.remoteCmd != defaultRemoteClaudeCmd {
		t.Errorf("remoteCmd = %q, quero default %q", tgt.remoteCmd, defaultRemoteClaudeCmd)
	}
	if tgt.prog != "ssh" {
		t.Errorf("prog = %q, quero \"ssh\"", tgt.prog)
	}
}

// TestSetRemoteClaudeCmdOverridesDefault cobre o campo configurável pedido na
// Fase 5 (o claude pode estar fora do PATH, ex.: ~/.local/bin).
func TestSetRemoteClaudeCmdOverridesDefault(t *testing.T) {
	tgt := NewSSHTarget("macmini", "remote-host")
	tgt.SetRemoteClaudeCmd("/Users/example/.local/bin/claude")
	if tgt.remoteCmd != "/Users/example/.local/bin/claude" {
		t.Errorf("remoteCmd = %q após SetRemoteClaudeCmd", tgt.remoteCmd)
	}

	// Valor vazio é ignorado — mantém o que já estava configurado.
	tgt.SetRemoteClaudeCmd("")
	if tgt.remoteCmd != "/Users/example/.local/bin/claude" {
		t.Errorf("remoteCmd = %q, SetRemoteClaudeCmd(\"\") não deveria sobrescrever", tgt.remoteCmd)
	}
}

// TestSSHClaudeArgsHaveKeepaliveBatchModeNoPTY verifica exatamente os args
// reais passados ao `ssh`: BatchMode, keepalive, -T (sem PTY), destino, e o
// comando remoto num login shell.
func TestSSHClaudeArgsHaveKeepaliveBatchModeNoPTY(t *testing.T) {
	args := sshClaudeArgs("macmini", defaultRemoteClaudeCmd, "", "")

	wantPrefix := []string{
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "StrictHostKeyChecking=accept-new",
		"-T",
		"--",
		"macmini",
	}
	if len(args) != len(wantPrefix)+1 {
		t.Fatalf("args = %v, quero %d elementos (opções+separador+destino+comando remoto)", args, len(wantPrefix)+1)
	}
	for i, want := range wantPrefix {
		if args[i] != want {
			t.Errorf("args[%d] = %q, quero %q (args completos: %v)", i, args[i], want, args)
		}
	}
	// O "--" deve vir imediatamente antes do destino (blindagem contra dest "-").
	if args[len(args)-3] != "--" || args[len(args)-2] != "macmini" {
		t.Errorf("esperava [..., \"--\", \"macmini\", <cmd remoto>]; got %v", args)
	}

	remote := args[len(args)-1]
	if !strings.Contains(remote, "bash -lc") {
		t.Errorf("comando remoto não roda em login shell: %q", remote)
	}
	for _, want := range []string{
		defaultRemoteClaudeCmd, "-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--permission-mode", "default",
		"--permission-prompt-tool", "stdio",
		"--verbose",
	} {
		if !strings.Contains(remote, want) {
			t.Errorf("comando remoto = %q, quero conter %q", remote, want)
		}
	}
}

// execPrefix é o wrapper que impede o `bash -lc` interno de reparsear os args
// como shell (SEC-101): cada arg vira parâmetro posicional, repassado por
// `exec "$0" "$@"`. Compartilhado pelos testes que checam o formato.
var execPrefix = "bash -lc " + singleQuote(`exec "$0" "$@"`)

// TestRemoteClaudeCommandUsesConfiguredPath garante que trocar o comando/caminho
// do claude remoto (SetRemoteClaudeCmd) se reflete no comando enviado por ssh,
// já como $0 single-quoted do wrapper exec "$0" "$@".
func TestRemoteClaudeCommandUsesConfiguredPath(t *testing.T) {
	got := remoteClaudeCommand("/Users/example/.local/bin/claude", "", "")
	if !strings.HasPrefix(got, execPrefix+" ") {
		t.Errorf("remoteClaudeCommand não usa o wrapper exec \"$0\" \"$@\":\n  %s", got)
	}
	// O caminho do claude entra como $0, single-quoted.
	if !strings.Contains(got, execPrefix+" "+singleQuote("/Users/example/.local/bin/claude")+" ") {
		t.Errorf("remoteClaudeCommand = %q, quero o caminho configurado como $0 quotado", got)
	}
	// Cada flag verificada aparece como arg quotado.
	for _, flag := range []string{"-p", "--input-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio"} {
		if !strings.Contains(got, " "+singleQuote(flag)) {
			t.Errorf("remoteClaudeCommand sem a flag quotada %q:\n  %s", flag, got)
		}
	}
}

// TestRemoteClaudeCommandWithCwdPrefixesCd garante que cwd != "" vira um
// `cd <cwd> &&` (single-quoted) antes do `bash -lc` — o cd é builtin do shell
// não-interativo do sshd, e o `bash -lc` seguinte herda o cwd do pai.
func TestRemoteClaudeCommandWithCwdPrefixesCd(t *testing.T) {
	got := remoteClaudeCommand(defaultRemoteClaudeCmd, "", "/tmp/algum diretório")
	wantPrefix := "cd " + singleQuote("/tmp/algum diretório") + " && " + execPrefix + " "
	if !strings.HasPrefix(got, wantPrefix) {
		t.Errorf("remoteClaudeCommand com cwd =\n  %s\nquero prefixo:\n  %s", got, wantPrefix)
	}
}

// TestRemoteClaudeCommandNeutralizesInjection é o teste de regressão do SEC-101:
// um resumeID malicioso (controlável pelo cliente via Adopt) NUNCA pode virar
// comando, mesmo executado como o sshd faz — `login_shell -c "<cmd>"` com um
// `bash -lc` aninhado. Constrói o comando real, roda-o num shell (simulando o
// sshd) com um `claude` falso que registra o próprio argv, e prova que (a)
// nenhum comando injetado rodou e (b) o payload chegou como UM único argumento.
func TestRemoteClaudeCommandNeutralizesInjection(t *testing.T) {
	dir := t.TempDir()
	sentinel := filepath.Join(dir, "PWNED")
	argvOut := filepath.Join(dir, "argv.txt")
	// claude falso: grava cada arg recebido em argv.txt (um por linha).
	fakeClaude := filepath.Join(dir, "claude")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + singleQuote(argvOut) + "\n"
	if err := os.WriteFile(fakeClaude, []byte(script), 0o755); err != nil {
		t.Fatalf("escrever fake claude: %v", err)
	}

	payloads := []string{
		"abc; touch " + sentinel + " #",
		"abc && touch " + sentinel,
		"abc$(touch " + sentinel + ")",
		"abc`touch " + sentinel + "`",
		"$(touch " + sentinel + ")",
	}
	for _, id := range payloads {
		t.Run(id, func(t *testing.T) {
			_ = os.Remove(sentinel)
			_ = os.Remove(argvOut)
			cmd := remoteClaudeCommand(fakeClaude, id, "")
			// Simula exatamente o que o sshd faz: login_shell -c "<cmd>".
			out, err := exec.Command("bash", "-c", cmd).CombinedOutput()
			if err != nil {
				t.Fatalf("rodar comando: %v\nsaída: %s", err, out)
			}
			if _, err := os.Stat(sentinel); err == nil {
				t.Fatalf("INJEÇÃO: comando embutido no id rodou (sentinela criada) para id=%q", id)
			}
			// O claude falso deve ter rodado e recebido o id como UM arg intacto.
			got, err := os.ReadFile(argvOut)
			if err != nil {
				t.Fatalf("claude falso não rodou (sem argv.txt) para id=%q: %v", id, err)
			}
			if !strings.Contains(string(got), id) {
				t.Errorf("id não chegou intacto como arg único.\nargv:\n%s\nquero conter: %q", got, id)
			}
		})
	}
}

// TestSSHTargetRunnerProcessesFixtureViaFakeProgram prova que o Handle
// devolvido pelo SSHTarget é consumível pelo Runner exatamente como o do
// LocalTarget — troca o binário `ssh` real por `cat` sobre uma fixture (não dá
// para depender de ssh real em teste), no mesmo espírito de
// TestLocalTargetExecsCommand.
func TestSSHTargetRunnerProcessesFixtureViaFakeProgram(t *testing.T) {
	path := filepath.Join("testdata", "fixture-simple.jsonl")
	tgt := newSSHCommand("macmini", "dest-irrelevante-para-o-fake", defaultRemoteClaudeCmd, "cat",
		func(dest, remoteCmd, _, _ string) []string { return []string{path} })

	if tgt.Name() != "macmini" {
		t.Errorf("Name() = %q, quero \"macmini\"", tgt.Name())
	}

	h, err := tgt.Start(context.Background(), "", "", "", "", "")
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer h.Close()

	reg := registry.New()
	eng := engine.New(reg)
	r := NewRunner(eng)
	if err := r.Run(context.Background(), h, Meta{Machine: "macmini", Prompt: "explique a arquitetura"}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	s, ok := reg.Get("ea6c037a-4306-479b-acc7-d5bd0cf52941")
	if !ok {
		t.Fatalf("sessão da fixture não foi criada via SSHTarget")
	}
	if s.State != session.StateDone {
		t.Errorf("State = %q, quero \"done\"", s.State)
	}
	if s.Machine != "macmini" {
		t.Errorf("Machine = %q, quero \"macmini\"", s.Machine)
	}
}

// TestSSHTargetDoesNotLeakHubEnv é o SEC-006 aplicado ao processo ssh: mesma
// allowlist do LocalTarget, HOME presente (ssh precisa dela p/ achar chaves).
func TestSSHTargetDoesNotLeakHubEnv(t *testing.T) {
	t.Setenv("CUTUQUE_TOKEN", "super-secreto-sentinela")
	t.Setenv("CUTUQUE_TEST_SENTINELA", "vazou")

	tgt := newSSHCommand("macmini", "dest-irrelevante-para-o-fake", defaultRemoteClaudeCmd, "env",
		func(dest, remoteCmd, _, _ string) []string { return nil })

	h, err := tgt.Start(context.Background(), "", "", "", "", "")
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
		t.Fatalf("ambiente do hub vazou para o processo ssh:\n%s", env)
	}
	if !strings.Contains(env, "HOME=") {
		t.Errorf("HOME deveria estar na allowlist (ssh precisa achar ~/.ssh/config e chaves):\n%s", env)
	}
}

func TestModelEffortFlags(t *testing.T) {
	// Válidos entram.
	got := modelEffortFlags("opus", "high")
	want := "--model opus --effort high"
	if strings.Join(got, " ") != want {
		t.Errorf("modelEffortFlags(opus,high) = %v, quero %q", got, want)
	}
	// Nome completo válido.
	if f := modelEffortFlags("claude-opus-4-8", "max"); strings.Join(f, " ") != "--model claude-opus-4-8 --effort max" {
		t.Errorf("nome completo/max rejeitado: %v", f)
	}
	// Ausentes → nada.
	if f := modelEffortFlags("", ""); len(f) != 0 {
		t.Errorf("vazios deviam dar nada, got %v", f)
	}
	// Effort inválido é descartado; model com metachar é rejeitado.
	if f := modelEffortFlags("opus; rm -rf ~", "turbo"); len(f) != 0 {
		t.Errorf("valores inválidos deviam ser rejeitados, got %v", f)
	}
}
