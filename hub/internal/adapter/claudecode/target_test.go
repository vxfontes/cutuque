package claudecode

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
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
	h, err := tgt.Start(context.Background(), "", "", "", "", "", "")
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
	h, err := tgt.Start(context.Background(), "", "", "", "", "", "")
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
	h, startErr := tgt.Start(context.Background(), "", dir, "", "", "", "")
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
	h, err := tgt.Start(context.Background(), "", "", "", "", "", "")
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

// MARK: identidade das máquinas cadastradas pelo app

// Máquina cadastrada pela aba Máquinas conecta com a chave que o hub gerou e o
// known_hosts próprio — não com o ~/.ssh do container.
func TestIdentidadeDaMaquinaEntraNasOperacoesDeArquivo(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	tgt.SetIdentity("/data/machines/keys/vps", "/data/machines/known_hosts", 22)

	args := tgt.downloadArgs("/tmp/notas.md")
	for _, quero := range []string{
		"/data/machines/keys/vps",
		"IdentitiesOnly=yes",
		"UserKnownHostsFile=/data/machines/known_hosts",
		"StrictHostKeyChecking=yes",
	} {
		if !slices.Contains(args, quero) {
			t.Errorf("faltou %q nos args: %v", quero, args)
		}
	}
	// A primeira ocorrência de StrictHostKeyChecking é a que o ssh honra.
	if i := primeiroStrict(args); i == "" || i != "StrictHostKeyChecking=yes" {
		t.Errorf("o accept-new venceu a checagem estrita: %v", args)
	}
}

// O Start também: lançar sessão numa máquina do app não pode escapar para o
// ~/.ssh do container.
func TestIdentidadeDaMaquinaEntraNoComandoDeLancamento(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	tgt.SetIdentity("/data/machines/keys/vps", "/data/machines/known_hosts", 22)

	args := agent.WithIdentity(tgt.identity, tgt.buildArgs(tgt.dest, tgt.remoteCmd, "", ""))
	if !slices.Contains(args, "/data/machines/keys/vps") {
		t.Errorf("o lançamento não usa a chave da máquina: %v", args)
	}
	if primeiroStrict(args) != "StrictHostKeyChecking=yes" {
		t.Errorf("o lançamento aceitaria chave nova em silêncio: %v", args)
	}
}

// Porta fora da padrão precisa entrar na linha: o keyscan gravou a entrada como
// "[host]:2222" no known_hosts e o ssh só casa essa linha conectando lá.
func TestPortaDoCadastroEntraNaLinhaDeSsh(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	tgt.SetIdentity("/data/machines/keys/vps", "/data/machines/known_hosts", 2222)

	args := tgt.downloadArgs("/tmp/notas.md")
	i := slices.Index(args, "-p")
	if i == -1 || i+1 >= len(args) || args[i+1] != "2222" {
		t.Errorf("faltou -p 2222 nos args: %v", args)
	}
}

// Máquina do hub.env segue exatamente como antes: sem -i, sem known_hosts
// próprio, com o accept-new de sempre.
func TestMaquinaDoEnvNaoGanhaIdentidadeNenhuma(t *testing.T) {
	tgt := NewSSHTarget("macmini", "macmini")
	args := tgt.downloadArgs("/tmp/x")
	if slices.Contains(args, "-i") || slices.Contains(args, "IdentitiesOnly=yes") {
		t.Errorf("máquina do env ganhou identidade que não é dela: %v", args)
	}
	if primeiroStrict(args) != "StrictHostKeyChecking=accept-new" {
		t.Errorf("o comportamento da máquina do env mudou: %v", args)
	}
}

// MARK: terminal livre

// O terminal livre é o único uso de ssh que QUER um tty do outro lado. Pedir o
// `-tt` e ao mesmo tempo deixar escapar o `-T` do uso em lote daria um shell sem
// terminal: sem prompt, sem vim, sem htop.
func TestShellCommandPedeTerminalENaoMandaComando(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	cmd := tgt.ShellCommand(context.Background())

	args := cmd.Args[1:] // [0] é o próprio prog
	if !slices.Contains(args, "-tt") {
		t.Errorf("faltou -tt (shell sem terminal do outro lado): %v", args)
	}
	if slices.Contains(args, "-T") {
		t.Errorf("o -T do uso em lote vazou para o terminal livre: %v", args)
	}
	// Nenhum comando remoto: o destino sozinho faz o ssh abrir o login shell.
	// Se sobrar algo depois do dest, o ssh roda AQUILO e sai.
	if args[len(args)-1] != tgt.dest {
		t.Errorf("args terminam em %q, quero o dest %q sem comando depois: %v",
			args[len(args)-1], tgt.dest, args)
	}
	// BatchMode fica: um prompt de senha num terminal que ninguém vê pendura a
	// conexão em vez de falhar.
	if !slices.Contains(args, "BatchMode=yes") {
		t.Errorf("sem BatchMode o terminal penduraria num prompt de senha: %v", args)
	}
}

// Máquina cadastrada pelo app abre terminal com a chave dela e o known_hosts
// próprio — o terminal não pode ser a porta dos fundos que escapa do TOFU.
func TestShellCommandUsaAIdentidadeDaMaquina(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	tgt.SetIdentity("/data/machines/keys/vps", "/data/machines/known_hosts", 2222)

	args := tgt.ShellCommand(context.Background()).Args[1:]
	for _, quero := range []string{
		"/data/machines/keys/vps",
		"IdentitiesOnly=yes",
		"UserKnownHostsFile=/data/machines/known_hosts",
		"-p", "2222",
	} {
		if !slices.Contains(args, quero) {
			t.Errorf("faltou %q nos args do terminal: %v", quero, args)
		}
	}
	if primeiroStrict(args) != "StrictHostKeyChecking=yes" {
		t.Errorf("o terminal aceitaria chave nova em silêncio: %v", args)
	}
}

// O terminal livre precisa ANUNCIAR um terminal de verdade. Em produção o hub é
// um container sem tty: a allowlist do ChildEnv não acha TERM nenhum para
// copiar, o `ssh` não tem o que mandar e o remoto assume o mínimo — TERM=dumb.
// Aí `tmux attach` recusa ("terminal does not support clear") e todo `tput` do
// bashrc reclama na abertura. Quem desenha a tela é o SwiftTerm do app, um
// emulador xterm; é isso que tem de ir no fio.
func TestShellCommandDeclaraTerminalDeVerdade(t *testing.T) {
	// Duas situações e a MESMA resposta: o TERM do processo do hub não entra na
	// conta, porque não é ele que renderiza nada.
	casos := map[string]func(){
		"hub sem tty (produção)": func() { os.Unsetenv("TERM") },
		"hub rodado de um terminal exótico": func() {
			os.Setenv("TERM", "xterm-ghostty") // terminfo que o remoto pode não ter
		},
	}
	for nome, prepara := range casos {
		t.Run(nome, func(t *testing.T) {
			t.Setenv("TERM", "irrelevante") // só para o cleanup restaurar o original
			prepara()

			env := NewSSHTarget("vps", "vx@192.0.2.50").ShellCommand(context.Background()).Env

			var terms []string
			for _, kv := range env {
				if strings.HasPrefix(kv, "TERM=") {
					terms = append(terms, kv)
				}
			}
			// UMA entrada só: env duplicado é lido pela PRIMEIRA ocorrência por
			// quem usa getenv, então "sobrescrever por cima" não sobrescreve nada.
			if len(terms) != 1 {
				t.Fatalf("quero exatamente um TERM no ambiente, tenho %v (env: %v)", terms, env)
			}
			if terms[0] != "TERM="+agent.TerminalTERM {
				t.Errorf("TERM do terminal livre é %q, quero %q", terms[0], "TERM="+agent.TerminalTERM)
			}
			// E a allowlist continua de pé: sem HOME o ssh não acha config, chave
			// nem known_hosts.
			if !slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, "HOME=") }) {
				t.Errorf("o HOME sumiu do ambiente do terminal: %v", env)
			}
		})
	}
}

// primeiroStrict devolve o valor da PRIMEIRA opção StrictHostKeyChecking — a
// única que o ssh leva em conta.
func primeiroStrict(args []string) string {
	for _, a := range args {
		if strings.HasPrefix(a, "StrictHostKeyChecking=") {
			return a
		}
	}
	return ""
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

	h, err := tgt.Start(context.Background(), "", "", "", "", "", "")
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

	h, err := tgt.Start(context.Background(), "", "", "", "", "", "")
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
