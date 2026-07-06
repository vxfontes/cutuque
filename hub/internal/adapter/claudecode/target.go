package claudecode

import (
	"context"
	"os/exec"
	"regexp"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

// Tipos da plataforma de execução, reexportados por alias do pacote agent — o
// código (e os testes) que já referenciam claudecode.Handle/Target/… seguem
// compilando sem mudança, e o codex compartilha a mesma base.
type (
	Handle          = agent.Handle
	Meta            = agent.Meta
	Applier         = agent.Applier
	Runner          = agent.Runner
	Target          = agent.Target
	Discoverer      = agent.Discoverer
	Liver           = agent.Liver
	DirLister       = agent.DirLister
	Transcriber     = agent.Transcriber
	TranscriptChunk = agent.TranscriptChunk
)

// childEnv/singleQuote: finos wrappers dos helpers compartilhados do pacote
// agent (mantêm os call sites internos do claudecode intactos).
func childEnv() []string          { return agent.ChildEnv() }
func singleQuote(s string) string { return agent.SingleQuote(s) }

const agentKind = "claude-code"

var (
	// Effort do claude: só os níveis válidos passam (--effort <level>).
	validEffortLevel = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
	// Model: alias (opus/sonnet/haiku/fable) ou nome completo (claude-...). Padrão
	// estrito — defesa em profundidade além do single-quote (SEC-101).
	modelNamePattern = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,40}$`)
)

// modelEffortFlags devolve as flags --model/--effort do claude, VALIDADAS: só
// valores conhecidos passam; ausente/inválido → nada.
func modelEffortFlags(model, effort string) []string {
	var f []string
	if modelNamePattern.MatchString(model) {
		f = append(f, "--model", model)
	}
	if validEffortLevel[effort] {
		f = append(f, "--effort", effort)
	}
	return f
}

// LocalTarget roda o Claude Code como um processo local, em modo stream-json
// bidirecional. Em produção executa (verificado na CLI 2.1.198):
//
//	claude -p --input-format stream-json --output-format stream-json \
//	       --permission-mode default --permission-prompt-tool stdio --verbose
//
// Nesse modo o CLI emite control_request (can_use_tool) no stdout e aguarda o
// control_response no stdin — o canal de aprovação nativo do Cutuque.
type LocalTarget struct {
	name      string
	prog      string
	buildArgs func(resumeID string) []string
}

// claudeFlags monta as flags do `claude` verificadas, com `--resume <id>` quando
// resumeID != "" (continuar a conversa anterior).
func claudeFlags(resumeID string) []string {
	args := []string{"-p"}
	if resumeID != "" {
		args = append(args, "--resume", resumeID)
	}
	return append(args,
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--permission-mode", "default",
		"--permission-prompt-tool", "stdio",
		"--verbose",
	)
}

// NewLocalTarget cria um LocalTarget que roda o `claude` real localmente.
func NewLocalTarget(name string) *LocalTarget {
	return newLocalCommand(name, "claude", claudeFlags)
}

// newLocalCommand cria um LocalTarget parametrizável (usado em teste para trocar
// `claude` por um comando como `cat` de uma fixture).
func newLocalCommand(name, prog string, buildArgs func(resumeID string) []string) *LocalTarget {
	return &LocalTarget{name: name, prog: prog, buildArgs: buildArgs}
}

// Name identifica o alvo (vira o campo Machine da sessão).
func (t *LocalTarget) Name() string { return t.name }

// Kind identifica o agente deste alvo.
func (t *LocalTarget) Kind() string { return agentKind }

// NewRunner devolve o Runner com o parser do Claude (stream-json) e o rótulo
// "claude-code".
func (t *LocalTarget) NewRunner(app Applier) *Runner { return NewRunner(app) }

// Start executa o comando e liga stdin/stdout ao Handle. Fechar o Handle
// encerra o processo (via cancelamento do ctx + close do stdin) e libera os
// recursos. resumeID != "" continua a conversa existente. cwd != "" muda o
// diretório de trabalho do processo (vazio → home, herdado do hub). prompt != ""
// é enviado pelo stdin logo após o start (o Handle segue vivo para replies).
func (t *LocalTarget) Start(ctx context.Context, resumeID, cwd, model, effort, prompt string) (*Handle, error) {
	// model/effort (quando escolhidos no app) viram flags extras do claude.
	args := append(t.buildArgs(resumeID), modelEffortFlags(model, effort)...)
	cmd := exec.CommandContext(ctx, t.prog, args...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	// Ambiente mínimo explícito (SEC-006): o filho NÃO herda CUTUQUE_TOKEN etc.
	cmd.Env = childEnv()
	h, err := startHandle(cmd)
	if err != nil {
		return nil, err
	}
	if err := sendInitialPrompt(h, prompt); err != nil {
		return nil, err
	}
	return h, nil
}

// defaultRemoteClaudeCmd é o comando/caminho do claude remoto quando nada é
// configurado — assume que está no PATH do login shell remoto.
const defaultRemoteClaudeCmd = "claude"

// SSHTarget roda o Claude Code numa máquina remota via `ssh`, no MESMO shape
// bidirecional do LocalTarget: Start devolve um *Handle cujo Stdin/Stdout são
// pipes limpos (SEM PTY) ligados ao stream-json do `claude` do outro lado.
//
// O comando remoto roda dentro de um login shell (`bash -lc`) para carregar o
// PATH completo do usuário (o `claude` costuma estar em ~/.local/bin).
type SSHTarget struct {
	name      string
	dest      string // destino ssh: alias do ~/.ssh/config OU user@host
	remoteCmd string // caminho/comando do claude remoto (default: "claude")
	prog      string // programa ssh local (parametrizável em teste)
	buildArgs func(dest, remoteCmd, resumeID, cwd string) []string
}

// NewSSHTarget cria um SSHTarget que conecta a `dest` e roda o `claude` real lá.
func NewSSHTarget(name, dest string) *SSHTarget {
	return newSSHCommand(name, dest, defaultRemoteClaudeCmd, "ssh", sshClaudeArgs)
}

// newSSHCommand cria um SSHTarget parametrizável (usado em teste para trocar o
// binário `ssh` local por um fake).
func newSSHCommand(name, dest, remoteCmd, prog string, buildArgs func(dest, remoteCmd, resumeID, cwd string) []string) *SSHTarget {
	return &SSHTarget{name: name, dest: dest, remoteCmd: remoteCmd, prog: prog, buildArgs: buildArgs}
}

// SetRemoteClaudeCmd sobrescreve o caminho/comando do claude remoto. Vazio é
// ignorado (mantém o default/atual).
func (t *SSHTarget) SetRemoteClaudeCmd(cmd string) {
	if cmd != "" {
		t.remoteCmd = cmd
	}
}

// Name identifica o alvo remoto (vira o campo Machine da sessão).
func (t *SSHTarget) Name() string { return t.name }

// Kind identifica o agente deste alvo.
func (t *SSHTarget) Kind() string { return agentKind }

// NewRunner devolve o Runner do Claude (stream-json, "claude-code").
func (t *SSHTarget) NewRunner(app Applier) *Runner { return NewRunner(app) }

// Start conecta via ssh e liga stdin/stdout (pipes limpos, sem PTY) ao Handle.
// cwd != "" vira um `cd <cwd> &&` antes do comando remoto. prompt != "" é
// enviado pelo stdin logo após o start.
func (t *SSHTarget) Start(ctx context.Context, resumeID, cwd, model, effort, prompt string) (*Handle, error) {
	sshArgs := t.buildArgs(t.dest, t.remoteCmd, resumeID, cwd)
	// model/effort entram como MAIS parâmetros posicionais do `exec "$0" "$@"`
	// remoto (single-quoted, mesmo escape do SEC-101), anexados ao comando remoto
	// (último arg). Só quando escolhidos, então o fake dos testes ("", "") não muda.
	if extra := modelEffortFlags(model, effort); len(extra) > 0 && len(sshArgs) > 0 {
		q := make([]string, len(extra))
		for i, a := range extra {
			q[i] = singleQuote(a)
		}
		sshArgs[len(sshArgs)-1] += " " + strings.Join(q, " ")
	}
	cmd := exec.CommandContext(ctx, t.prog, sshArgs...)
	// Mesma allowlist do LocalTarget (SEC-006). HOME é essencial para o ssh achar
	// ~/.ssh/config, as chaves privadas e o known_hosts.
	cmd.Env = childEnv()
	h, err := startHandle(cmd)
	if err != nil {
		return nil, err
	}
	if err := sendInitialPrompt(h, prompt); err != nil {
		return nil, err
	}
	return h, nil
}

// startHandle liga os pipes de um cmd e o inicia, devolvendo o Handle.
func startHandle(cmd *exec.Cmd) (*Handle, error) {
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return agent.NewHandle(stdout, stdin, cmd), nil
}

// sendInitialPrompt manda o prompt inicial pelo stdin (formato stream-json do
// Claude). Vazio → não faz nada (ex.: resume sem texto). Em erro fecha o Handle.
func sendInitialPrompt(h *Handle, prompt string) error {
	if prompt == "" {
		return nil
	}
	if err := h.SendUserMessage(prompt); err != nil {
		_ = h.Close()
		return err
	}
	return nil
}

// sshBaseOpts são as opções de ssh compartilhadas por todo uso (o claude e a
// descoberta). Compartilhar evita divergência entre os dois.
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

// sshClaudeArgs monta os args do `ssh` local para rodar o claude remoto.
func sshClaudeArgs(dest, remoteCmd, resumeID, cwd string) []string {
	return append(sshBaseOpts(),
		"--", // separador: um dest começando com "-" nunca é reinterpretado como opção
		dest,
		remoteClaudeCommand(remoteCmd, resumeID, cwd),
	)
}

// remoteClaudeCommand monta a linha de comando remota (dois níveis de parse de
// shell — ver o comentário histórico do SEC-101). Passa cada arg como parâmetro
// posicional de `bash -lc 'exec "$0" "$@"'` para o nível 2 não reparsear input.
func remoteClaudeCommand(claudeCmd, resumeID, cwd string) string {
	claudeArgs := []string{claudeCmd, "-p"}
	if resumeID != "" {
		claudeArgs = append(claudeArgs, "--resume", resumeID)
	}
	claudeArgs = append(claudeArgs,
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--permission-mode", "default",
		"--permission-prompt-tool", "stdio",
		"--verbose",
	)
	quoted := make([]string, len(claudeArgs))
	for i, a := range claudeArgs {
		quoted[i] = singleQuote(a)
	}
	cmd := "bash -lc " + singleQuote(`exec "$0" "$@"`) + " " + strings.Join(quoted, " ")
	if cwd != "" {
		cmd = "cd " + singleQuote(cwd) + " && " + cmd
	}
	return cmd
}
