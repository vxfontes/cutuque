package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// tmuxPathPrefix garante que o `tmux` seja achado numa sessão ssh não-interativa
// (o PATH reduzido não costuma ter o Homebrew). Prepende os diretórios comuns ao
// PATH do shell remoto — `$PATH` é expandido LÁ (não localmente).
const tmuxPathPrefix = `export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"; `

// tmuxListScript lista os panes do tmux e mantém só os que têm um `claude` na
// ÁRVORE DE PROCESSOS do pane — robusto contra o nome do binário (o claude roda
// como `versions/<semver>`, cujo pane_current_command é só "2.1.200") e contra
// flicker (quando o claude spawna um `bash`, ele continua na árvore). Emite
// [{id,cmd,cwd,session,window}]. Prepende PATH para achar tmux numa sessão ssh
// não-interativa. python3 do sistema (macOS).
const tmuxListScript = `import subprocess,json,os,re
os.environ['PATH']=os.environ.get('PATH','')+':/opt/homebrew/bin:/usr/local/bin:/opt/local/bin'
def run(*a):
    try: return subprocess.run(list(a),capture_output=True,text=True).stdout
    except Exception: return ''
fmt='#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{session_name}\t#{window_name}'
panes=run('tmux','list-panes','-a','-F',fmt)
kids={}; cmd={}
for line in run('ps','-axo','pid=,ppid=,command=').splitlines():
    m=re.match(r'\s*(\d+)\s+(\d+)\s+(.*)',line)
    if not m: continue
    pid,ppid,c=int(m.group(1)),int(m.group(2)),m.group(3)
    cmd[pid]=c; kids.setdefault(ppid,[]).append(pid)
def has_claude(root):
    seen=set(); stack=[root]
    while stack:
        p=stack.pop()
        if p in seen: continue
        seen.add(p)
        c=cmd.get(p,'').lower()
        if 'claude' in c and 'daemon' not in c and 'bg-pty-host' not in c: return True
        stack+=kids.get(p,[])
    return False
out=[]
for line in panes.splitlines():
    f=line.split('\t')
    if len(f)<5: continue
    try: pid=int(f[1])
    except: continue
    if not has_claude(pid): continue
    out.append({'id':f[0],'cmd':'claude','cwd':f[2],'session':f[3],'window':f[4]})
print(json.dumps(out))
`

// tmuxPaneIDPattern valida um pane id do tmux (ex.: "%12"). Usado como defesa em
// profundidade antes de interpolar o alvo num comando remoto.
var tmuxPaneIDPattern = regexp.MustCompile(`^%[0-9]+$`)

// TmuxPane é um pane do tmux rodando (provavelmente) um claude, com o id estável
// (%N) usado como alvo de capture/send-keys.
type TmuxPane struct {
	ID      string `json:"id"`      // pane_id estável (ex.: "%12")
	Cmd     string `json:"cmd"`     // comando em foreground no pane
	Cwd     string `json:"cwd"`     // diretório do pane
	Session string `json:"session"` // nome da sessão tmux
	Window  string `json:"window"`  // nome da janela tmux
}

// Tmuxer controla sessões do Claude rodando dentro do tmux numa máquina: listar
// os panes, espelhar a tela (capture) e digitar (send-keys) — a ponte que faz a
// mensagem do celular cair no terminal que já está rodando. SSHTarget e
// LocalTarget o satisfazem.
type Tmuxer interface {
	TmuxList(ctx context.Context) ([]TmuxPane, error)
	TmuxCapture(ctx context.Context, target string) (string, error)
	TmuxSend(ctx context.Context, target, text string) error
	// TmuxKey envia uma tecla nomeada (Ctrl+C, setas, Esc…) ao pane.
	TmuxKey(ctx context.Context, target, key string) error
	// TmuxResize fixa a janela do pane em cols×rows (window-size manual) para o
	// terminal caber bem no celular mesmo com o terminal do Mac enorme. cols<=0
	// restaura o dimensionamento automático (window-size latest) — chamado ao
	// fechar o espelho para a visão no Mac voltar ao normal.
	TmuxResize(ctx context.Context, target string, cols, rows int) error
}

// parseTmuxJSON converte a saída do tmuxListScript ([{id,cmd,cwd,session,window}])
// em []TmuxPane. Saída vazia/inválida → nil (sem panes).
func parseTmuxJSON(out []byte) []TmuxPane {
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return nil
	}
	var raw []struct {
		ID      string `json:"id"`
		Cmd     string `json:"cmd"`
		Cwd     string `json:"cwd"`
		Session string `json:"session"`
		Window  string `json:"window"`
	}
	if err := json.Unmarshal([]byte(trimmed), &raw); err != nil {
		return nil
	}
	panes := make([]TmuxPane, 0, len(raw))
	for _, r := range raw {
		panes = append(panes, TmuxPane{ID: r.ID, Cmd: r.Cmd, Cwd: r.Cwd, Session: r.Session, Window: r.Window})
	}
	return panes
}

// validTarget checa o pane id antes de usá-lo num comando remoto.
func validTarget(target string) error {
	if !tmuxPaneIDPattern.MatchString(target) {
		return fmt.Errorf("claudecode: pane id inválido: %q", target)
	}
	return nil
}

// --- SSHTarget ---------------------------------------------------------------

// runSSHTmux roda um comando remoto (via ssh) e devolve o stdout. inner já deve
// vir com os argumentos escapados; o prefixo de PATH é adicionado aqui.
func (t *SSHTarget) runSSHTmux(ctx context.Context, inner string) ([]byte, error) {
	args := append(sshBaseOpts(), "--", t.dest, tmuxPathPrefix+inner)
	cmd := exec.CommandContext(ctx, t.prog, args...)
	cmd.Env = childEnv()
	return cmd.Output()
}

// TmuxList lista os panes do tmux rodando claude na máquina remota (via script
// python que checa a árvore de processos de cada pane).
func (t *SSHTarget) TmuxList(ctx context.Context) ([]TmuxPane, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	cmd := exec.CommandContext(ctx, t.prog, args...)
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(tmuxListScript)
	out, err := cmd.Output()
	if err != nil {
		// tmux sem servidor / python indisponível — trata como sem panes.
		return nil, nil
	}
	return parseTmuxJSON(out), nil
}

// tmuxScrollback é quantas linhas de histórico (além da tela visível) são
// capturadas, para a usuária rolar e ler o que já saiu da tela.
const tmuxScrollback = 500

// TmuxCapture devolve a tela do pane + histórico (scrollback), COM as sequências
// de cor ANSI (-e) para o app renderizar as cores reais do claude. `-S -N` pega
// N linhas para trás; `-J` junta linhas quebradas por wrap.
func (t *SSHTarget) TmuxCapture(ctx context.Context, target string) (string, error) {
	if err := validTarget(target); err != nil {
		return "", err
	}
	out, err := t.runSSHTmux(ctx, "tmux capture-pane -t "+singleQuote(target)+" -e -p -S -"+strconv.Itoa(tmuxScrollback))
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// tmuxAllowedKeys são as teclas nomeadas que o app pode enviar (send-keys sem
// -l). Allowlist estrita: nada fora daqui vira comando remoto (defesa contra
// injeção via nome de tecla).
var tmuxAllowedKeys = map[string]bool{
	"C-c": true, "C-d": true, "C-z": true, "C-l": true,
	"Escape": true, "Enter": true, "Tab": true, "BSpace": true, "Space": true,
	"Up": true, "Down": true, "Left": true, "Right": true,
	"PageUp": true, "PageDown": true, "Home": true, "End": true,
}

// TmuxKey envia uma TECLA NOMEADA ao pane (Ctrl+C, setas, Esc, Enter…), para o
// app controlar o TUI (interromper, navegar subagentes). Só teclas da allowlist.
func (t *SSHTarget) TmuxKey(ctx context.Context, target, key string) error {
	if err := validTarget(target); err != nil {
		return err
	}
	if !tmuxAllowedKeys[key] {
		return fmt.Errorf("claudecode: tecla não permitida: %q", key)
	}
	_, err := t.runSSHTmux(ctx, "tmux send-keys -t "+singleQuote(target)+" "+key)
	return err
}

// TmuxResize fixa (cols>0) ou restaura (cols<=0) o tamanho da janela do pane.
func (t *SSHTarget) TmuxResize(ctx context.Context, target string, cols, rows int) error {
	if err := validTarget(target); err != nil {
		return err
	}
	tq := singleQuote(target)
	var inner string
	if cols > 0 && rows > 0 {
		inner = "tmux set-window-option -t " + tq + " window-size manual; " +
			"tmux resize-window -t " + tq + " -x " + strconv.Itoa(cols) + " -y " + strconv.Itoa(rows)
	} else {
		inner = "tmux set-window-option -t " + tq + " window-size latest"
	}
	_, err := t.runSSHTmux(ctx, inner)
	return err
}

// TmuxSend digita `text` literalmente no pane e submete (Enter). text é
// single-quoted (um só nível de shell no ssh; sem bash -lc aninhado), então
// metacaracteres do texto do usuário nunca viram comando.
func (t *SSHTarget) TmuxSend(ctx context.Context, target, text string) error {
	if err := validTarget(target); err != nil {
		return err
	}
	tq := singleQuote(target)
	// -l = literal (não interpreta nomes de tecla); `--` separa do texto que
	// possa começar com '-'. Depois um Enter (tecla) para submeter ao claude.
	inner := "tmux send-keys -t " + tq + " -l -- " + singleQuote(text) +
		"; tmux send-keys -t " + tq + " Enter"
	_, err := t.runSSHTmux(ctx, inner)
	return err
}

// --- LocalTarget (execução local; usado em teste e na própria máquina) -------

func (t *LocalTarget) TmuxList(ctx context.Context) ([]TmuxPane, error) {
	cmd := exec.CommandContext(ctx, "python3", "-")
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(tmuxListScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, nil
	}
	return parseTmuxJSON(out), nil
}

func (t *LocalTarget) TmuxCapture(ctx context.Context, target string) (string, error) {
	if err := validTarget(target); err != nil {
		return "", err
	}
	out, err := exec.CommandContext(ctx, "tmux", "capture-pane", "-t", target, "-e", "-p", "-S", "-"+strconv.Itoa(tmuxScrollback)).Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func (t *LocalTarget) TmuxKey(ctx context.Context, target, key string) error {
	if err := validTarget(target); err != nil {
		return err
	}
	if !tmuxAllowedKeys[key] {
		return fmt.Errorf("claudecode: tecla não permitida: %q", key)
	}
	return exec.CommandContext(ctx, "tmux", "send-keys", "-t", target, key).Run()
}

func (t *LocalTarget) TmuxResize(ctx context.Context, target string, cols, rows int) error {
	if err := validTarget(target); err != nil {
		return err
	}
	if cols > 0 && rows > 0 {
		_ = exec.CommandContext(ctx, "tmux", "set-window-option", "-t", target, "window-size", "manual").Run()
		return exec.CommandContext(ctx, "tmux", "resize-window", "-t", target, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows)).Run()
	}
	return exec.CommandContext(ctx, "tmux", "set-window-option", "-t", target, "window-size", "latest").Run()
}

func (t *LocalTarget) TmuxSend(ctx context.Context, target, text string) error {
	if err := validTarget(target); err != nil {
		return err
	}
	if err := exec.CommandContext(ctx, "tmux", "send-keys", "-t", target, "-l", "--", text).Run(); err != nil {
		return err
	}
	return exec.CommandContext(ctx, "tmux", "send-keys", "-t", target, "Enter").Run()
}

// TmuxPaneAsDiscovered adapta um TmuxPane ao shape Discovered (reuso do modelo
// do app): title = nome da sessão tmux (o que a usuária nomeou), com fallback
// para a última pasta do cwd quando o nome é auto-gerado (só dígitos) ou vazio.
// A janela é ignorada (o tmux costuma nomeá-la com o comando, ex.: "2.1.200").
func TmuxPaneAsDiscovered(p TmuxPane) session.Discovered {
	title := p.Session
	if title == "" || isAllDigits(title) {
		if base := lastPathComponent(p.Cwd); base != "" {
			title = base
		}
	}
	return session.Discovered{ID: p.ID, Cwd: p.Cwd, Title: title}
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func lastPathComponent(p string) string {
	p = strings.TrimRight(p, "/")
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[i+1:]
	}
	return p
}
