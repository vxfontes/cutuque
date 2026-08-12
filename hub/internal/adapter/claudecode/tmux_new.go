package claudecode

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
)

// tmuxNewSessionAgents mapeia o agente escolhido no app para o comando que roda no
// pane. Copiado do scripts/tmx.sh da Vanessa (claude :153, codex :164,
// opencode :175, shell puro :59) para que app e terminal dêem a MESMA coisa — D10.
// Comando vazio = shell, que é o terminal livre da D8.
var tmuxNewSessionAgents = map[string]string{
	"claude":   "claude",
	"codex":    "codex --sandbox danger-full-access",
	"opencode": "opencode",
	"terminal": "",
}

// tmuxNamePattern valida nome de grupo e de sessão. O tmux usa ":" e "." como
// separador de alvo (sessão:janela.pane) e o grupo virá um dia num caminho de
// socket — nome fora deste alfabeto produz alvo ambíguo, não erro legível. É a
// mesma regra que o formulário do app aplica no teclado (D12).
var tmuxNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// tmuxAbsPathPattern exige pasta absoluta e de alfabeto seguro (mesmo conjunto do
// tmuxSocketPattern) antes de interpolar num comando remoto.
var tmuxAbsPathPattern = regexp.MustCompile(`^/[A-Za-z0-9._/ -]+$`)

// tmuxNewSpec é uma criação já validada: nada além disto chega a virar comando.
type tmuxNewSpec struct {
	Group   string // = o socket do tmux (-L), e o mesmo identificador do escopo do board
	Session string
	Cwd     string
	Command string // vazio = shell puro
}

// tmuxNewFormat pede de volta o caminho do socket e o pane criado, que juntos são o
// alvo composto que o resto do hub usa ("<socket>\t<pane>").
const tmuxNewFormat = "#{socket_path}\t#{pane_id}"

func validarNovaSessao(group, session, cwd, agent string) (tmuxNewSpec, error) {
	if !tmuxNamePattern.MatchString(group) {
		return tmuxNewSpec{}, fmt.Errorf("claudecode: grupo inválido: %q", group)
	}
	if !tmuxNamePattern.MatchString(session) {
		return tmuxNewSpec{}, fmt.Errorf("claudecode: sessão inválida: %q", session)
	}
	if !tmuxAbsPathPattern.MatchString(cwd) {
		return tmuxNewSpec{}, fmt.Errorf("claudecode: pasta inválida: %q", cwd)
	}
	cmd, ok := tmuxNewSessionAgents[agent]
	if !ok {
		return tmuxNewSpec{}, fmt.Errorf("claudecode: agente desconhecido: %q", agent)
	}
	return tmuxNewSpec{Group: group, Session: session, Cwd: cwd, Command: cmd}, nil
}

// localArgs monta os args do tmux local. -A anexa se a sessão já existir (a spec
// trata "já existe" como sucesso, não erro) e -d evita anexar o terminal do hub.
func (n tmuxNewSpec) localArgs() []string {
	args := []string{"-L", n.Group, "new-session", "-A", "-d", "-s", n.Session,
		"-c", n.Cwd, "-P", "-F", tmuxNewFormat}
	if n.Command != "" {
		args = append(args, n.Command)
	}
	return args
}

func (n tmuxNewSpec) sshInner() string {
	inner := "tmux -L " + singleQuote(n.Group) + " new-session -A -d -s " + singleQuote(n.Session) +
		" -c " + singleQuote(n.Cwd) + " -P -F " + singleQuote(tmuxNewFormat)
	if n.Command != "" {
		inner += " " + singleQuote(n.Command)
	}
	return inner
}

// parseNovaSessao converte a saída do -P -F no alvo composto. Normaliza o
// /private/tmp para /tmp igual ao `norm` do script de varredura — senão o alvo
// devolvido aqui não casaria com nenhuma linha da lista ao vivo.
func parseNovaSessao(out []byte) (string, error) {
	linha := strings.TrimSpace(string(out))
	if i := strings.IndexByte(linha, '\n'); i >= 0 {
		linha = strings.TrimSpace(linha[:i])
	}
	partes := strings.SplitN(linha, "\t", 2)
	if len(partes) != 2 {
		return "", fmt.Errorf("claudecode: saída inesperada do new-session: %q", linha)
	}
	socket := strings.TrimPrefix(partes[0], "/private")
	target := socket + "\t" + partes[1]
	if _, _, err := parseTarget(target); err != nil {
		return "", err
	}
	return target, nil
}

// TmuxNewSession cria (ou anexa, pelo -A) uma sessão no servidor do grupo e devolve
// o alvo composto do pane. O grupo é o socket: `tmux -L <grupo>` cria o servidor na
// hora, sem registro nenhum — é por isso que grupo novo não tem cerimônia (D13).
func (t *SSHTarget) TmuxNewSession(ctx context.Context, group, session, cwd, agent string) (string, error) {
	spec, err := validarNovaSessao(group, session, cwd, agent)
	if err != nil {
		return "", err
	}
	out, err := t.runSSHTmux(ctx, spec.sshInner())
	if err != nil {
		return "", err
	}
	return parseNovaSessao(out)
}

func (t *LocalTarget) TmuxNewSession(ctx context.Context, group, session, cwd, agent string) (string, error) {
	spec, err := validarNovaSessao(group, session, cwd, agent)
	if err != nil {
		return "", err
	}
	cmd := exec.CommandContext(ctx, "tmux", spec.localArgs()...)
	cmd.Env = childEnv()
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return parseNovaSessao(out)
}
