package codex

import (
	"context"
	"os/exec"
	"regexp"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

const (
	agentKind = "codex"
	// defaultSandbox: workspace-write deixa o Codex editar dentro da pasta de
	// trabalho (o ponto de uma tarefa de código) mas isola o resto. Fase 3 deixa
	// a usuária escolher (read-only / workspace-write / danger-full-access).
	defaultSandbox = "workspace-write"
)

var (
	// Effort de raciocínio do Codex (GPT-5). Allowlist estrita: vira valor de
	// config (-c model_reasoning_effort=...); só valores conhecidos passam.
	validEffort = map[string]bool{"minimal": true, "low": true, "medium": true, "high": true}
	// Model: nome do modelo (ex.: gpt-5-codex, o3). Padrão estrito — defesa em
	// profundidade além do single-quote (SEC-101).
	modelNamePattern = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,80}$`)
	// defaultRemoteCodexCmd: assume `codex` no PATH do login shell remoto.
	defaultRemoteCodexCmd = "codex"
)

// codexArgs monta os argumentos do `codex` (sem o programa) para lançar/retomar
// uma sessão em modo one-shot streaming. resumeID != "" → `exec resume <id>`
// (o resume não aceita -s/-C; o sandbox vai por -c e o cwd é o gravado na
// sessão). prompt vai após `--` para nunca ser confundido com uma flag.
func codexArgs(resumeID, model, effort, sandbox, prompt string) []string {
	var a []string
	if resumeID != "" {
		a = []string{"exec", "resume", resumeID, "--json", "--skip-git-repo-check",
			"-c", "sandbox_mode=" + tomlStr(sandbox)}
	} else {
		a = []string{"exec", "--json", "--skip-git-repo-check", "-s", sandbox}
	}
	if modelNamePattern.MatchString(model) {
		a = append(a, "-m", model)
	}
	if validEffort[effort] {
		a = append(a, "-c", "model_reasoning_effort="+tomlStr(effort))
	}
	if prompt != "" {
		a = append(a, "--", prompt)
	}
	return a
}

// tomlStr envolve um valor (sempre de allowlist: sandbox/effort) numa string TOML
// para o -c parsear como string, não como bareword.
func tomlStr(s string) string { return `"` + s + `"` }

// LocalTarget roda o `codex` como processo local, em modo `exec --json`.
type LocalTarget struct {
	name    string
	prog    string
	sandbox string
}

// NewLocalTarget cria um LocalTarget que roda o `codex` real localmente.
func NewLocalTarget(name string) *LocalTarget {
	return &LocalTarget{name: name, prog: "codex", sandbox: defaultSandbox}
}

func (t *LocalTarget) Name() string                  { return t.name }
func (t *LocalTarget) Kind() string                  { return agentKind }
func (t *LocalTarget) NewRunner(app agent.Applier) *agent.Runner {
	return agent.NewRunner(app, ParseLine, agentKind)
}

// Start dispara `codex exec [resume <id>] --json … -- <prompt>` localmente. O
// prompt vai como argumento (Codex é one-shot); o stdin é /dev/null para o Codex
// ver EOF na hora e não pendurar esperando input.
func (t *LocalTarget) Start(ctx context.Context, resumeID, cwd, model, effort, prompt string) (*agent.Handle, error) {
	args := codexArgs(resumeID, model, effort, t.sandbox, prompt)
	cmd := exec.CommandContext(ctx, t.prog, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = agent.ChildEnv()
	return startCodex(cmd)
}

// SSHTarget roda o `codex` numa máquina remota via `ssh`, no mesmo shape do
// LocalTarget (stdout em pipe limpo). O comando remoto roda dentro de um login
// shell (`bash -lc`) para carregar o PATH completo (o `codex` costuma estar em
// /opt/homebrew/bin ou ~/.local/bin).
type SSHTarget struct {
	name      string
	dest      string
	remoteCmd string
	prog      string
	sandbox   string
}

// NewSSHTarget cria um SSHTarget que conecta a `dest` e roda o `codex` real lá.
func NewSSHTarget(name, dest string) *SSHTarget {
	return &SSHTarget{name: name, dest: dest, remoteCmd: defaultRemoteCodexCmd, prog: "ssh", sandbox: defaultSandbox}
}

// SetRemoteCodexCmd sobrescreve o caminho/comando do codex remoto. Vazio ignora.
func (t *SSHTarget) SetRemoteCodexCmd(cmd string) {
	if cmd != "" {
		t.remoteCmd = cmd
	}
}

func (t *SSHTarget) Name() string                  { return t.name }
func (t *SSHTarget) Kind() string                  { return agentKind }
func (t *SSHTarget) NewRunner(app agent.Applier) *agent.Runner {
	return agent.NewRunner(app, ParseLine, agentKind)
}

// Start conecta via ssh e roda o codex remoto. cwd != "" vira `cd <cwd> &&`.
func (t *SSHTarget) Start(ctx context.Context, resumeID, cwd, model, effort, prompt string) (*agent.Handle, error) {
	remote := remoteCodexCommand(t.remoteCmd, codexArgs(resumeID, model, effort, t.sandbox, prompt), cwd)
	sshArgs := append(sshBaseOpts(), "--", t.dest, remote)
	cmd := exec.CommandContext(ctx, t.prog, sshArgs...)
	cmd.Env = agent.ChildEnv()
	return startCodex(cmd)
}

// startCodex liga o stdout a um Handle e inicia o processo com stdin em
// /dev/null (Codex é one-shot: o prompt já está no argumento; stdin fechado
// evita que ele pendure esperando input).
func startCodex(cmd *exec.Cmd) (*agent.Handle, error) {
	cmd.Stdin = nil // /dev/null → EOF imediato
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return agent.NewHandle(stdout, nil, cmd), nil
}

// sshBaseOpts espelha as opções de ssh do claudecode (BatchMode, timeouts,
// keepalive, sem PTY) para o stream sair limpo.
func sshBaseOpts() []string {
	return []string{
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "StrictHostKeyChecking=accept-new",
		"-T",
	}
}

// remoteCodexCommand monta a linha remota com o mesmo escape de dois níveis do
// claudecode (SEC-101): cada arg como parâmetro posicional de
// `bash -lc 'exec "$0" "$@"'`, para o nível 2 não reparsear o prompt.
func remoteCodexCommand(codexCmd string, args []string, cwd string) string {
	all := append([]string{codexCmd}, args...)
	quoted := make([]string, len(all))
	for i, a := range all {
		quoted[i] = agent.SingleQuote(a)
	}
	cmd := "bash -lc " + agent.SingleQuote(`exec "$0" "$@"`) + " " + strings.Join(quoted, " ")
	if cwd != "" {
		cmd = "cd " + agent.SingleQuote(cwd) + " && " + cmd
	}
	return cmd
}
