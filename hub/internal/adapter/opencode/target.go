package opencode

import (
	"context"
	"os/exec"
	"regexp"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

const agentKind = "opencode"

var (
	// Variant (esforço de raciocínio, específico do provider): allowlist estrita.
	validVariant = map[string]bool{"minimal": true, "low": true, "medium": true, "high": true, "max": true}
	// Model no formato provider/model (ex.: openai/gpt-5.4-mini, zai/glm-4.5-flash).
	// Permite a barra; padrão estrito (SEC-101, defesa em profundidade).
	modelNamePattern     = regexp.MustCompile(`^[a-zA-Z0-9._/-]{1,60}$`)
	defaultRemoteCodeCmd = "opencode"
	// defaultModel é injetado quando nenhum modelo (válido) é escolhido: o
	// `opencode run` SEM `-m` fica pendurado (não há default configurado), então
	// nunca deixamos o `-m` de fora. openai está autenticado por padrão aqui.
	defaultModel = "openai/gpt-5.4-mini"
)

// ocArgs monta os argumentos do `opencode` (sem o programa). resumeID != "" →
// `-s <id>` (continua a sessão). O `--dangerously-skip-permissions` é
// OBRIGATÓRIO: em modo não-interativo o `run` sem ele fica pendurado esperando
// uma aprovação que ninguém pode dar (o hub não tem TTY). É a mesma postura de
// confiança do sandbox permissivo do Codex — a máquina-alvo é a do usuário.
func ocArgs(resumeID, cwd, model, variant, prompt string) []string {
	a := []string{"run", "--format", "json", "--dangerously-skip-permissions"}
	if cwd != "" {
		a = append(a, "--dir", cwd)
	}
	if resumeID != "" {
		a = append(a, "-s", resumeID)
	}
	// -m SEMPRE presente (senão o run pendura): usa o escolhido se válido, senão
	// o default seguro.
	if !modelNamePattern.MatchString(model) {
		model = defaultModel
	}
	a = append(a, "-m", model)
	if validVariant[variant] {
		a = append(a, "--variant", variant)
	}
	if prompt != "" {
		// `--` separa: um prompt começando com "-" (ex.: "-1") não pode ser lido
		// como flag pelo yargs do opencode (mesmo cuidado do Codex).
		a = append(a, "--", prompt)
	}
	return a
}

// LocalTarget roda o `opencode` como processo local, em `run --format json`.
type LocalTarget struct {
	name string
	prog string
}

func NewLocalTarget(name string) *LocalTarget { return &LocalTarget{name: name, prog: "opencode"} }

func (t *LocalTarget) Name() string { return t.name }
func (t *LocalTarget) Kind() string { return agentKind }
func (t *LocalTarget) NewRunner(app agent.Applier) *agent.Runner {
	return agent.NewRunner(app, newParser(), agentKind)
}

// Start dispara `opencode run --format json … <prompt>` localmente. Prompt como
// argumento (one-shot); stdin /dev/null (EOF imediato, não pendura). O parâmetro
// sandbox é ignorado (o OpenCode usa o modelo de permissão próprio, sempre com
// skip em modo não-interativo).
func (t *LocalTarget) Start(ctx context.Context, resumeID, cwd, model, effort, _sandbox, prompt string) (*agent.Handle, error) {
	cmd := exec.CommandContext(ctx, t.prog, ocArgs(resumeID, cwd, model, effort, prompt)...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	cmd.Env = agent.ChildEnv()
	return startOC(cmd)
}

// SSHTarget roda o `opencode` numa máquina remota via ssh (mesmo shape).
type SSHTarget struct {
	name      string
	dest      string
	remoteCmd string
	prog      string
}

func NewSSHTarget(name, dest string) *SSHTarget {
	return &SSHTarget{name: name, dest: dest, remoteCmd: defaultRemoteCodeCmd, prog: "ssh"}
}

// SetRemoteOpencodeCmd sobrescreve o caminho/comando do opencode remoto.
func (t *SSHTarget) SetRemoteOpencodeCmd(cmd string) {
	if cmd != "" {
		t.remoteCmd = cmd
	}
}

func (t *SSHTarget) Name() string { return t.name }
func (t *SSHTarget) Kind() string { return agentKind }
func (t *SSHTarget) NewRunner(app agent.Applier) *agent.Runner {
	return agent.NewRunner(app, newParser(), agentKind)
}

func (t *SSHTarget) Start(ctx context.Context, resumeID, cwd, model, effort, _sandbox, prompt string) (*agent.Handle, error) {
	// cwd vai no --dir do próprio opencode (não num cd), porque o remoto pode
	// não ter a pasta no PATH do login shell; --dir é explícito.
	remote := remoteOCCommand(t.remoteCmd, ocArgs(resumeID, cwd, model, effort, prompt))
	sshArgs := append(sshBaseOpts(), "--", t.dest, remote)
	cmd := exec.CommandContext(ctx, t.prog, sshArgs...)
	cmd.Env = agent.ChildEnv()
	return startOC(cmd)
}

// startOC liga o stdout a um Handle e inicia o processo com stdin em /dev/null
// (one-shot: prompt no argumento; stdin fechado evita pendurar).
func startOC(cmd *exec.Cmd) (*agent.Handle, error) {
	cmd.Stdin = nil
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return agent.NewHandle(stdout, nil, cmd), nil
}

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

// remoteOCCommand: mesmo escape de dois níveis do SEC-101 (cada arg como
// parâmetro posicional de `bash -lc 'exec "$0" "$@"'`).
func remoteOCCommand(ocCmd string, args []string) string {
	all := append([]string{ocCmd}, args...)
	quoted := make([]string, len(all))
	for i, a := range all {
		quoted[i] = agent.SingleQuote(a)
	}
	return "bash -lc " + agent.SingleQuote(`exec "$0" "$@"`) + " " + strings.Join(quoted, " ")
}
