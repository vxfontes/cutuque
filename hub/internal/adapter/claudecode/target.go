package claudecode

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// closeWaitTimeout é quanto Close espera o processo sair sozinho (após fechar
// stdin/stdout) antes de matar com SIGKILL. Sem esse teto, um filho pendurado
// (ex.: ssh travado no connect) faria Close — e o graceful shutdown — travar
// para sempre (review F5, achado bloqueante #1).
const closeWaitTimeout = 5 * time.Second

// Handle é o canal bidirecional de uma sessão viva do Claude Code: lê-se o
// stream-json pelo Stdout e escreve-se pelo Stdin (mensagens de usuário e
// control_response de aprovação/negação). Fechar encerra o processo.
//
// As escritas passam por WriteJSON/SendUserMessage, serializadas por writeMu:
// aprovar e enviar texto podem vir de goroutines diferentes (handlers HTTP) e
// não podem intercalar bytes numa mesma linha do stdin.
type Handle struct {
	Stdout  io.ReadCloser
	Stdin   io.WriteCloser
	wait    func() error // cmd.Wait — colhe o processo
	kill    func() error // cmd.Process.Kill (SIGKILL) — fallback do Close
	writeMu sync.Mutex

	// closeOnce garante um único cmd.Wait(): Close pode ser chamado em corrida
	// pelo timeout do Launch e pelo fim natural do Runner, e Wait concorrente é
	// data race na stdlib (review F3, achado #1).
	closeOnce sync.Once
	closeErr  error
}

// Close fecha o stdin (sinaliza EOF ao agente) e espera o processo terminar,
// para não deixar zumbis. É seguro (e idempotente) chamar de várias goroutines:
// só a primeira executa; as demais recebem o mesmo resultado. Se o processo não
// sair em closeWaitTimeout (ex.: ssh pendurado), é morto com SIGKILL — Close
// nunca bloqueia indefinidamente (review F5, achado bloqueante #1).
func (h *Handle) Close() error {
	h.closeOnce.Do(func() {
		if h.Stdin != nil {
			_ = h.Stdin.Close()
		}
		if h.Stdout != nil {
			_ = h.Stdout.Close()
		}
		if h.wait == nil {
			return
		}
		done := make(chan error, 1)
		go func() { done <- h.wait() }()
		select {
		case err := <-done:
			h.closeErr = err
		case <-time.After(closeWaitTimeout):
			if h.kill != nil {
				_ = h.kill()
			}
			h.closeErr = <-done // Wait retorna após o SIGKILL
		}
	})
	return h.closeErr
}

// procKill devolve uma função que mata o processo do cmd com SIGKILL (nil-safe).
func procKill(cmd *exec.Cmd) func() error {
	return func() error {
		if cmd.Process != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
}

// userMessage é a mensagem de usuário no formato stream-json que o CLI aceita
// no stdin (verificado na CLI 2.1.198):
//
//	{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}
type userMessage struct {
	Type    string          `json:"type"`
	Message userMessageBody `json:"message"`
}

type userMessageBody struct {
	Role    string         `json:"role"`
	Content []userTextItem `json:"content"`
}

type userTextItem struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// WriteJSON serializa v em uma linha JSON (com newline) no stdin, de forma
// thread-safe. É como o Launcher escreve o control_response de aprovação/negação.
func (h *Handle) WriteJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	_, err = h.Stdin.Write(b)
	return err
}

// SendUserMessage escreve uma mensagem de usuário (o prompt inicial ou um input
// posterior) no stdin, no formato stream-json seguido de newline.
func (h *Handle) SendUserMessage(text string) error {
	return h.WriteJSON(userMessage{
		Type: "user",
		Message: userMessageBody{
			Role:    "user",
			Content: []userTextItem{{Type: "text", Text: text}},
		},
	})
}

// Target é uma máquina/canal onde uma sessão do Claude Code é lançada e
// observada. Start dispara a sessão e devolve um Handle bidirecional; o prompt
// inicial é enviado por quem lança, via Handle.SendUserMessage.
// resumeID != "" → continua a conversa existente (claude --resume <id>),
// preservando o contexto do turno anterior (mesmo session_id — verificado na
// CLI 2.1.199). Vazio → sessão nova.
// cwd é a pasta onde o `claude` roda; vazio → home (comportamento atual).
type Target interface {
	Name() string
	Start(ctx context.Context, resumeID, cwd string) (*Handle, error)
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

// Start executa o comando e liga stdin/stdout ao Handle. Fechar o Handle
// encerra o processo (via cancelamento do ctx + close do stdin) e libera os
// recursos. resumeID != "" continua a conversa existente. cwd != "" muda o
// diretório de trabalho do processo (vazio → home, herdado do hub).
func (t *LocalTarget) Start(ctx context.Context, resumeID, cwd string) (*Handle, error) {
	cmd := exec.CommandContext(ctx, t.prog, t.buildArgs(resumeID)...)
	if cwd != "" {
		cmd.Dir = cwd
	}
	// Ambiente mínimo explícito: o filho NÃO herda o ambiente do hub, que
	// carrega CUTUQUE_TOKEN (e, no futuro, credenciais APNs). Sem isso, um
	// `printenv` — que roda sem passar pelo gate de aprovação (docs/10,
	// armadilha #2) — exfiltraria o token no output (review F3, SEC-006).
	cmd.Env = childEnv()
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
	return &Handle{
		Stdout: stdout,
		Stdin:  stdin,
		wait:   cmd.Wait,
		kill:   procKill(cmd),
	}, nil
}

// childEnv monta o ambiente mínimo do processo do agente: só o necessário para
// o `claude` funcionar (HOME p/ config/credenciais, PATH p/ binários, locale).
// Allowlist, nunca herança de os.Environ() (review F3, SEC-006).
func childEnv() []string {
	keep := []string{"HOME", "PATH", "USER", "LANG", "LC_ALL", "TERM", "TMPDIR"}
	env := make([]string, 0, len(keep))
	for _, k := range keep {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// defaultRemoteClaudeCmd é o comando/caminho do claude remoto quando nada é
// configurado — assume que está no PATH do login shell remoto. Máquinas onde o
// claude mora fora do PATH (ex.: instalado via npm em ~/.local/bin sem symlink
// em /usr/local/bin) precisam de SetRemoteClaudeCmd com o caminho absoluto.
const defaultRemoteClaudeCmd = "claude"

// SSHTarget roda o Claude Code numa máquina remota via `ssh`, no MESMO shape
// bidirecional do LocalTarget: Start devolve um *Handle cujo Stdin/Stdout são
// pipes limpos (SEM PTY) ligados ao stream-json do `claude` do outro lado —
// docs/02 chama isso de "native-first" via `tailscale ssh`/ssh direto.
//
// O comando remoto roda dentro de um login shell (`bash -lc`): uma sessão ssh
// não-interativa normalmente só carrega /etc/profile (não o rc do shell do
// usuário), e o `claude` costuma estar em ~/.local/bin ou similar — fora desse
// PATH reduzido (docs/superpowers/plans/2026-07-02-fase-5, "reconhecimento do
// servidor"). O login shell garante que o PATH completo do usuário remoto seja
// carregado antes de procurar o `claude`.
type SSHTarget struct {
	name      string
	dest      string // destino ssh: alias do ~/.ssh/config OU user@host
	remoteCmd string // caminho/comando do claude remoto (default: "claude")
	prog      string // programa ssh local (parametrizável em teste)
	buildArgs func(dest, remoteCmd, resumeID, cwd string) []string
}

// NewSSHTarget cria um SSHTarget que conecta a `dest` (alias do ~/.ssh/config
// ou user@host) e roda o `claude` real lá, com o comando verificado na CLI
// 2.1.198 (mesmas flags do LocalTarget — docs/10).
func NewSSHTarget(name, dest string) *SSHTarget {
	return newSSHCommand(name, dest, defaultRemoteClaudeCmd, "ssh", sshClaudeArgs)
}

// newSSHCommand cria um SSHTarget parametrizável (usado em teste para trocar o
// binário `ssh` local por um fake — ex. `cat`/`env` sobre uma fixture — e
// inspecionar/injetar o stream, no mesmo espírito de newLocalCommand).
func newSSHCommand(name, dest, remoteCmd, prog string, buildArgs func(dest, remoteCmd, resumeID, cwd string) []string) *SSHTarget {
	return &SSHTarget{name: name, dest: dest, remoteCmd: remoteCmd, prog: prog, buildArgs: buildArgs}
}

// SetRemoteClaudeCmd sobrescreve o caminho/comando do claude remoto (ex.:
// "/Users/example/.local/bin/claude" quando não está nem no PATH do login
// shell remoto). Valores vazios são ignorados (mantém o default/atual).
func (t *SSHTarget) SetRemoteClaudeCmd(cmd string) {
	if cmd != "" {
		t.remoteCmd = cmd
	}
}

// Name identifica o alvo remoto (vira o campo Machine da sessão).
func (t *SSHTarget) Name() string { return t.name }

// Start conecta via ssh e liga stdin/stdout (pipes limpos, sem PTY) ao Handle.
// Fechar o Handle fecha o stdin do ssh local (EOF chega ao `claude` remoto) e
// espera o processo ssh terminar — mesmo shape do LocalTarget.Start. cwd != ""
// vira um `cd <cwd> &&` antes do comando remoto (ver remoteClaudeCommand).
func (t *SSHTarget) Start(ctx context.Context, resumeID, cwd string) (*Handle, error) {
	cmd := exec.CommandContext(ctx, t.prog, t.buildArgs(t.dest, t.remoteCmd, resumeID, cwd)...)
	// Mesma allowlist do LocalTarget (SEC-006): o processo ssh NÃO herda o
	// ambiente do hub além do necessário. HOME é essencial para o ssh achar
	// ~/.ssh/config, as chaves privadas e o known_hosts.
	cmd.Env = childEnv()
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
	return &Handle{
		Stdout: stdout,
		Stdin:  stdin,
		wait:   cmd.Wait,
		kill:   procKill(cmd),
	}, nil
}

// sshClaudeArgs monta os args reais passados ao binário `ssh` local:
//   - BatchMode=yes: nunca pede senha interativamente (o hub não tem TTY para
//     responder); falha rápido se a chave não autenticar sozinha.
//   - ServerAliveInterval/CountMax: keepalive da camada ssh — detecta o Mac
//     dormindo/rede caindo sem esperar o TCP timeout do SO.
//   - -T: desliga alocação de PTY (mesmo que o ~/.ssh/config do alias peça
//     "RequestTTY"), garantindo stdin/stdout como pipes limpos para o
//     protocolo stream-json — um PTY reescreveria/misturaria os bytes.
//   - o comando remoto roda o claude dentro de um login shell (ver comentário
//     do SSHTarget).
func sshClaudeArgs(dest, remoteCmd, resumeID, cwd string) []string {
	return []string{
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10", // não pendura no connect de host lento/inalcançável (review F5, #1)
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "StrictHostKeyChecking=accept-new", // explícito: não fica refém do ssh_config do host (review F5, segurança-ssh)
		"-T",
		"--", // separador: um dest começando com "-" nunca é reinterpretado como opção (review F5, injeção)
		dest,
		remoteClaudeCommand(remoteCmd, resumeID, cwd),
	}
}

// remoteClaudeCommand monta a linha de comando remota como UMA única string
// (para sobreviver à concatenação por espaço que o próprio ssh faz dos args
// finais antes de mandar ao shell de login remoto): `bash -lc '<claude com as
// flags verificadas>'`. cwd != "" prefixa com `cd <cwd> &&` (single-quoted);
// como `cd` é builtin do shell não-interativo que o sshd invoca, o diretório
// já está setado quando o `bash -lc` seguinte é executado (herda o cwd do pai).
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
	cmd := "bash -lc " + singleQuote(strings.Join(claudeArgs, " "))
	if cwd != "" {
		cmd = "cd " + singleQuote(cwd) + " && " + cmd
	}
	return cmd
}

// singleQuote envolve s em aspas simples (escapando aspas simples internas) —
// suficiente para os valores fixos/configurados aqui (caminho do claude e suas
// flags), não pretende ser um escapador de shell genérico para input externo.
func singleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
