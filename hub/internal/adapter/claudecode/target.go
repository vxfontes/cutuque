package claudecode

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Tipos da plataforma de execução, reexportados por alias do pacote agent — o
// código (e os testes) que já referenciam claudecode.Handle/Target/… seguem
// compilando sem mudança, e o codex compartilha a mesma base.
type (
	Handle            = agent.Handle
	Meta              = agent.Meta
	Applier           = agent.Applier
	Runner            = agent.Runner
	Target            = agent.Target
	Discoverer        = agent.Discoverer
	Liver             = agent.Liver
	TranscriptLister  = agent.TranscriptLister
	DirLister         = agent.DirLister
	FileLister        = agent.FileLister
	FileReader        = agent.FileReader
	FileWriter        = agent.FileWriter
	FileDownloader    = agent.FileDownloader
	GitDiffer         = agent.GitDiffer
	CodeServerStarter = agent.CodeServerStarter
	CodeServer        = session.CodeServer
	ShellDialer       = agent.ShellDialer
	Transcriber       = agent.Transcriber
	TranscriptChunk   = agent.TranscriptChunk
)

// childEnv/singleQuote: finos wrappers dos helpers compartilhados do pacote
// agent (mantêm os call sites internos do claudecode intactos).
func childEnv() []string          { return agent.ChildEnv() }
func shellEnv() []string          { return agent.ShellEnv() }
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
func (t *LocalTarget) Start(ctx context.Context, resumeID, cwd, model, effort, _sandbox, prompt string) (*Handle, error) {
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

// LocalShellTarget [16/08/2026] é um LocalTarget que TAMBÉM abre um shell
// dentro do próprio hub. Existe para UM caso só: a caixa pública de
// demonstração do review da App Store, onde o revisor precisa de um terminal de
// verdade mas não há (nem pode haver) máquina nenhuma do outro lado de um ssh.
//
// É um TIPO SEPARADO, e não um campo bool no LocalTarget, de propósito. A
// invariante que o hub mantém é "máquina local não tem shell" (ver ShellDialer
// em agent/target.go e Launcher.ShellCommand, que devolve ErrNoShell para ela) —
// e quem decide isso é uma type assertion. Um bool faria o LocalTarget satisfazer
// ShellDialer ESTATICAMENTE: a assertion passaria sempre, o ErrNoShell nunca mais
// aconteceria e a invariante morreria em produção junto. Com um tipo à parte, o
// LocalTarget de produção continua sem shell e nada no caminho de sempre muda.
//
// Só o main.go constrói isto, e só quando CUTUQUE_LOCAL_SHELL está ligado.
type LocalShellTarget struct {
	*LocalTarget
}

// NewLocalShellTarget cria o alvo local COM terminal. Ver LocalShellTarget para
// por que isto não é uma flag do NewLocalTarget.
func NewLocalShellTarget(name string) *LocalShellTarget {
	return &LocalShellTarget{LocalTarget: NewLocalTarget(name)}
}

// ShellCommand monta o shell interativo dentro do container do hub — o análogo
// local do SSHTarget.ShellCommand, e a única razão deste tipo existir.
//
// Três decisões, e o porquê de cada uma:
//
// `-i` e NÃO `-l`: um login shell serviria para carregar o PATH do perfil do
// usuário, mas aqui não precisa — o ShellEnv já carrega o PATH do próprio hub
// (ver agent.ChildEnv), que num container é o PATH bom. E `-l` teria custo: a
// imagem final é alpine, cujo /bin/sh é o busybox, e depender de uma flag que
// pode não existir lá trocaria um problema resolvido por um risco de runtime.
// `-i` é POSIX, todo shell aceita.
//
// ShellEnv e não childEnv: sem ele o TERM vai `dumb` e o SwiftTerm do app
// recebe um terminal que não sabe se limpar — a mesma armadilha documentada no
// SSHTarget.ShellCommand, que aqui morde igual.
//
// Sem cmd.Dir: o shell abre onde o hub roda. Apontar para o HOME parece mais
// simpático, mas HOME pode não existir no container, e Dir inexistente faz o
// exec falhar inteiro — um terminal que não abre é pior que um terminal que
// abre no diretório errado, e `cd` resolve o segundo.
//
// CUIDADO ao montar a imagem: `-i` faz o shell LER OS RC FILES (~/.bashrc, ou
// $ENV no busybox). O ambiente do processo está protegido pela allowlist do
// ShellEnv — verificado rodando o hub e pedindo o CUTUQUE_TOKEN pelo terminal,
// que voltou vazio —, mas o que estiver EXPORTADO num rc dentro da imagem
// aparece para quem digita. Numa alpine limpa não há rc nenhum; a imagem da
// caixa de demonstração precisa continuar assim.
func (t *LocalShellTarget) ShellCommand(ctx context.Context) *exec.Cmd {
	cmd := exec.CommandContext(ctx, localShellProg(), "-i")
	cmd.Env = shellEnv()
	return cmd
}

// localShellProg escolhe o shell do terminal local: o do usuário se declarado,
// senão bash se instalado, senão /bin/sh — que sempre existe, inclusive no
// alpine (busybox). Resolvido a cada chamada e não no boot: a checagem é barata
// perto de subir um pty, e assim a imagem pode ganhar um bash sem o hub precisar
// reiniciar para enxergá-lo.
func localShellProg() string {
	if sh := os.Getenv("SHELL"); sh != "" {
		return sh
	}
	if p, err := exec.LookPath("bash"); err == nil {
		return p
	}
	return "/bin/sh"
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
	// identity são as opções de chave/known_hosts das máquinas cadastradas
	// pelo app (vazio nas do hub.env, que usam o ~/.ssh do container).
	identity []string
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

// SetIdentity amarra o alvo à chave e ao known_hosts que o hub gerou no
// cadastro da máquina (aba Máquinas). Sem os dois, não faz nada: a máquina
// segue usando o ~/.ssh do container, como as do hub.env.
func (t *SSHTarget) SetIdentity(keyPath, knownHosts string, port int) {
	t.identity = agent.IdentityOpts(keyPath, knownHosts, port)
}

// sshOpts são as opções de ssh deste alvo: identidade da máquina (se houver)
// antes das compartilhadas — a ordem importa, ver agent.IdentityOpts.
func (t *SSHTarget) sshOpts() []string {
	return agent.WithIdentity(t.identity, sshBaseOpts())
}

// sshOptsDeConsulta são as opções deste alvo para uma LEITURA repetida (a
// listagem de panes, e agora a sondagem de alcance da aba Máquinas): iguais
// às normais, com ConnectTimeout curto.
func (t *SSHTarget) sshOptsDeConsulta() []string {
	return agent.WithIdentity(t.identity, sshBaseOptsConsulta())
}

// Prober é implementado pelo alvo que sabe confirmar alcance de VERDADE via
// ssh (só o SSHTarget). O LocalTarget não implementa — é o próprio hub, sem
// ssh no meio, então a ausência da interface já basta como sinal de "sempre
// alcançável" para quem faz a type assertion (mesmo padrão de
// Discoverer/Liver/Tmuxer: capacidade opcional, resolvida por asserção).
type Prober interface {
	Probe(ctx context.Context) error
}

// Probe confere se esta máquina responde de VERDADE ao ssh: abre e fecha uma
// conexão real, sem tocar em tmux/python3/claude — só o comando remoto mais
// barato que existe (`true`), para o veredito não depender de nada estar
// instalado do outro lado além do próprio login shell. Usa o ConnectTimeout de
// CONSULTA (curto): é exatamente o "polling de fundo repetido" do comentário
// dela, nunca abrir/pilotar sessão (ver connectTimeoutConsulta). nil = ssh
// respondeu (a máquina está "pronto pra uso"); erro = não respondeu dentro do
// prazo, recusou a chave, ou qualquer outra falha — tudo cai no mesmo veredito
// "não respondeu", sem distinguir motivo (a aba Máquinas só quer saber se dá
// para usar agora).
func (t *SSHTarget) Probe(ctx context.Context) error {
	args := append(t.sshOptsDeConsulta(), "--", t.dest, "true")
	cmd := exec.CommandContext(ctx, t.prog, args...)
	cmd.Env = childEnv()
	return cmd.Run()
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
func (t *SSHTarget) Start(ctx context.Context, resumeID, cwd, model, effort, _sandbox, prompt string) (*Handle, error) {
	// A identidade entra aqui, e não no buildArgs: ele é um campo trocado por
	// fake nos testes e não conhece o alvo. Prefixar mantém a ordem certa
	// (identidade antes das opções base — ver agent.IdentityOpts).
	sshArgs := agent.WithIdentity(t.identity, t.buildArgs(t.dest, t.remoteCmd, resumeID, cwd))
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

// ShellCommand monta o `ssh` de um shell interativo nesta máquina — o terminal
// livre da aba Máquinas. Só monta: quem liga o PTY e roda é o handler do
// WebSocket.
//
// Duas diferenças em relação ao resto dos usos, e só elas: `-tt` no lugar do
// `-T`, porque aqui a gente QUER um terminal do outro lado (o `-tt` dobrado
// força mesmo com o stdin daqui não sendo um tty), e nenhum comando remoto — o
// destino sozinho faz o ssh abrir o login shell do usuário. O `BatchMode=yes`
// fica: sem chave instalada é melhor falhar na hora do que pendurar um prompt
// de senha que ninguém vê.
func (t *SSHTarget) ShellCommand(ctx context.Context) *exec.Cmd {
	opts := agent.WithIdentity(t.identity, append(sshOptsComuns(), "-tt"))
	// "--" separa: um dest começando com "-" nunca vira opção.
	cmd := exec.CommandContext(ctx, t.prog, append(opts, "--", t.dest)...)
	// Mesma allowlist do Start (SEC-006) — sem HOME o ssh não acha config, chave
	// nem known_hosts — mas com o TERM do terminal livre, e não o do hub: é o
	// `ssh` que anuncia o tipo de terminal ao remoto, e um hub sem tty anunciaria
	// dumb (ver agent.ShellEnv). É a terceira diferença deste uso, junto com o
	// `-tt` e a ausência de comando remoto.
	cmd.Env = shellEnv()
	return cmd
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

// ConnectTimeout do ssh, em segundos, em dois sabores — a distinção é entre
// AÇÃO (o usuário pediu e está esperando) e CONSULTA (polling de fundo).
//
// [13/08/2026] Antes havia só o valor de ação, usado por tudo. Com a máquina
// desligada, `GET /machines/windows/tmux` levava os 10s inteiros até o
// connect() estourar — e o app faz esse poll a cada 15s, então uma máquina
// off deixava o handler ocupado ~2/3 do tempo, de graça. A consulta desiste
// em 3s: se a máquina está de pé na LAN/Tailscale o TCP fecha em milissegundos,
// e se não está o resultado é o mesmo, só mais cedo. A abertura de sessão
// segue com 10s de propósito: ali o usuário mandou abrir, um handshake lento
// (VPN acordando, host sob carga) tem que ter chance de completar em vez de
// falhar na cara dele.
const (
	connectTimeoutAcao     = "10"
	connectTimeoutConsulta = "3"
)

// sshOptsComuns são as opções que valem para QUALQUER uso de ssh — em lote ou
// interativo. Ficam separadas do `-T` porque o terminal livre precisa do
// oposto dele, e é a única diferença entre os dois usos.
func sshOptsComuns() []string {
	return sshOptsComunsCom(connectTimeoutAcao)
}

// sshOptsComunsCom é sshOptsComuns com o ConnectTimeout escolhido pelo caller.
func sshOptsComunsCom(connectTimeout string) []string {
	return []string{
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=" + connectTimeout,
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "StrictHostKeyChecking=accept-new",
	}
}

// sshBaseOpts são as opções de ssh compartilhadas por todo uso em lote (o
// claude e a descoberta). Compartilhar evita divergência entre os dois.
func sshBaseOpts() []string {
	return append(sshOptsComuns(), "-T")
}

// sshBaseOptsConsulta é sshBaseOpts com o ConnectTimeout de consulta. Só para
// leitura repetida de fundo — nunca para abrir ou pilotar sessão.
func sshBaseOptsConsulta() []string {
	return append(sshOptsComunsCom(connectTimeoutConsulta), "-T")
}

// sshClaudeArgs monta os args do `ssh` local para rodar o claude remoto. As
// opções de identidade da máquina (quando há) são prefixadas pelo Start, que é
// quem conhece o alvo — esta função é um campo configurável do SSHTarget e os
// testes a trocam por um fake.
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
