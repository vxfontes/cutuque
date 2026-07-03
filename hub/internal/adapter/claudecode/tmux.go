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

// tmuxListScript lista os panes do tmux (de TODOS os servidores, inclusive os
// nomeados via `-L`, pois o tmx.sh da usuária agrupa por servidor) e mantém só
// os que têm um `claude` na ÁRVORE DE PROCESSOS do pane — robusto contra o nome
// do binário (`versions/<semver>`) e contra flicker (claude spawna `bash`).
// Emite [{id,socket,pane,cmd,cwd,session,window}] onde id = "<socket>\t<pane>"
// (alvo composto: pane_id só é único DENTRO de um servidor). python3 do sistema.
const tmuxListScript = `import subprocess,json,os,re,glob
os.environ['PATH']=os.environ.get('PATH','')+':/opt/homebrew/bin:/usr/local/bin:/opt/local/bin'
def run(*a):
    try: return subprocess.run(list(a),capture_output=True,text=True).stdout
    except Exception: return ''
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
def norm(x):
    # /tmp e /private/tmp são o mesmo dir no macOS (symlink); normaliza pra uma
    # forma só, senão o mesmo socket apareceria duas vezes e não casaria com o
    # socket que o hook reporta.
    return x[len('/private'):] if x.startswith('/private/') else x
work_re=re.compile(r'\((?:\d+m )?\d+s')
def pane_state(sock,pane):
    # Estado REAL da sessão lido do próprio terminal (independe dos hooks, então
    # sobrevive a restart do hub): captura a tela visível do pane e procura os
    # sinais da interface do Claude Code.
    #   - 'running' : trabalhando agora. Sinal principal = o TIMER VIVO do spinner
    #                 entre parênteses ("(8s" / "(4m 18s" — aparece enquanto gera/
    #                 roda ferramenta e some ao ficar ocioso). "esc to interrupt"
    #                 NÃO aparece no modo bypass-permissions, então não dá pra
    #                 depender só dele; "agent(s) to finish" = espera subagente.
    #   - 'waiting' : parado num diálogo de permissão/escolha ("Do you want to...").
    #   - 'idle'    : ocioso no prompt = concluiu o turno (é o "concluído" → verde).
    #                 (O status ocioso é passado: "Cogitated for 10s" — sem os
    #                 parênteses do timer vivo, então não casa com work_re.)
    txt=run('tmux','-S',sock,'capture-pane','-t',pane,'-p')
    low=txt.lower()
    if work_re.search(txt) or 'esc to interrupt' in low or 'agent to finish' in low or 'agents to finish' in low:
        return 'running'
    if 'do you want to proceed' in low or 'do you want to make this edit' in low:
        return 'waiting'
    return 'idle'
uid=os.getuid()
socks=set()
for d in ('/private/tmp/tmux-%d'%uid,'/tmp/tmux-%d'%uid,os.path.join(os.environ.get('TMPDIR','/tmp').rstrip('/'),'tmux-%d'%uid)):
    for s in glob.glob(d+'/*'):
        socks.add(norm(s))
fmt='#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{session_name}\t#{window_name}'
out=[]
for sock in sorted(socks):
    for line in run('tmux','-S',sock,'list-panes','-a','-F',fmt).splitlines():
        f=line.split('\t')
        if len(f)<5: continue
        try: pid=int(f[1])
        except: continue
        if not has_claude(pid): continue
        out.append({'id':sock+'\t'+f[0],'socket':sock,'pane':f[0],'cmd':'claude','cwd':f[2],'session':f[3],'window':f[4],'state':pane_state(sock,f[0])})
print(json.dumps(out))
`

// tmuxPaneIDPattern valida um pane id (ex.: "%12"); tmuxSocketPattern valida o
// caminho do socket do servidor tmux. Defesa em profundidade antes de interpolar.
var (
	tmuxPaneIDPattern = regexp.MustCompile(`^%[0-9]+$`)
	tmuxSocketPattern = regexp.MustCompile(`^/[A-Za-z0-9._/ -]+$`)
)

// TmuxPane é um pane do tmux rodando (provavelmente) um claude.
type TmuxPane struct {
	ID      string `json:"id"`      // alvo composto "<socket>\t<pane>"
	Cmd     string `json:"cmd"`     // sempre "claude" (filtrado)
	Cwd     string `json:"cwd"`     // diretório do pane
	Session string `json:"session"` // nome da sessão tmux
	Window  string `json:"window"`  // nome da janela tmux
	State   string `json:"state"`   // "running"|"waiting"|"idle" lido do terminal
}

// Tmuxer controla sessões do Claude rodando dentro do tmux numa máquina: listar
// os panes, espelhar a tela (capture) e digitar (send-keys/keys) — a ponte que
// faz a mensagem do celular cair no terminal que já roda. O alvo é o composto
// "<socket>\t<pane>". SSHTarget e LocalTarget o satisfazem.
type Tmuxer interface {
	TmuxList(ctx context.Context) ([]TmuxPane, error)
	TmuxCapture(ctx context.Context, target string) (string, error)
	TmuxSend(ctx context.Context, target, text string) error
	TmuxKey(ctx context.Context, target, key string) error
	TmuxResize(ctx context.Context, target string, cols, rows int) error
	TmuxKill(ctx context.Context, target string) error
}

// parseTmuxJSON converte a saída do tmuxListScript em []TmuxPane.
func parseTmuxJSON(out []byte) []TmuxPane {
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return nil
	}
	var raw []struct {
		ID, Cmd, Cwd, Session, Window, State string
	}
	if err := json.Unmarshal([]byte(trimmed), &raw); err != nil {
		return nil
	}
	panes := make([]TmuxPane, 0, len(raw))
	for _, r := range raw {
		panes = append(panes, TmuxPane{ID: r.ID, Cmd: r.Cmd, Cwd: r.Cwd, Session: r.Session, Window: r.Window, State: r.State})
	}
	return panes
}

// parseTarget separa o alvo composto "<socket>\t<pane>" e valida cada parte
// (socket pode vir vazio = servidor default). Rejeita valores fora do formato
// para nada perigoso chegar num comando remoto.
func parseTarget(target string) (socket, pane string, err error) {
	parts := strings.SplitN(target, "\t", 2)
	if len(parts) == 2 {
		socket, pane = parts[0], parts[1]
	} else {
		pane = parts[0]
	}
	if !tmuxPaneIDPattern.MatchString(pane) {
		return "", "", fmt.Errorf("claudecode: pane inválido: %q", pane)
	}
	if socket != "" && !tmuxSocketPattern.MatchString(socket) {
		return "", "", fmt.Errorf("claudecode: socket inválido: %q", socket)
	}
	return socket, pane, nil
}

// tmuxBase é o prefixo do comando tmux com o servidor certo (-S <socket>).
func tmuxBase(socket string) string {
	if socket == "" {
		return "tmux"
	}
	return "tmux -S " + singleQuote(socket)
}

// tmuxLocalArgs monta os args do tmux local com -S <socket> quando houver.
func tmuxLocalArgs(socket string, rest ...string) []string {
	if socket == "" {
		return rest
	}
	return append([]string{"-S", socket}, rest...)
}

// tmuxScrollback é quantas linhas de histórico são capturadas (scrollback do
// tmux; note que TUIs em tela alternada não têm scrollback — ver PageUp no app).
const tmuxScrollback = 500

// tmuxAllowedKeys são as teclas nomeadas que o app pode enviar (allowlist estrita).
var tmuxAllowedKeys = map[string]bool{
	"C-c": true, "C-d": true, "C-z": true, "C-l": true,
	"Escape": true, "Enter": true, "Tab": true, "BSpace": true, "Space": true,
	"Up": true, "Down": true, "Left": true, "Right": true,
	"PageUp": true, "PageDown": true, "Home": true, "End": true,
}

// --- SSHTarget ---------------------------------------------------------------

func (t *SSHTarget) runSSHTmux(ctx context.Context, inner string) ([]byte, error) {
	args := append(sshBaseOpts(), "--", t.dest, tmuxPathPrefix+inner)
	cmd := exec.CommandContext(ctx, t.prog, args...)
	cmd.Env = childEnv()
	return cmd.Output()
}

func (t *SSHTarget) TmuxList(ctx context.Context) ([]TmuxPane, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	cmd := exec.CommandContext(ctx, t.prog, args...)
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(tmuxListScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, nil
	}
	return parseTmuxJSON(out), nil
}

func (t *SSHTarget) TmuxCapture(ctx context.Context, target string) (string, error) {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return "", err
	}
	out, err := t.runSSHTmux(ctx, tmuxBase(socket)+" capture-pane -t "+singleQuote(pane)+" -e -p -S -"+strconv.Itoa(tmuxScrollback))
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func (t *SSHTarget) TmuxKey(ctx context.Context, target, key string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	if !tmuxAllowedKeys[key] {
		return fmt.Errorf("claudecode: tecla não permitida: %q", key)
	}
	_, err = t.runSSHTmux(ctx, tmuxBase(socket)+" send-keys -t "+singleQuote(pane)+" "+key)
	return err
}

func (t *SSHTarget) TmuxResize(ctx context.Context, target string, cols, rows int) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	b, pq := tmuxBase(socket), singleQuote(pane)
	var inner string
	if cols > 0 && rows > 0 {
		inner = b + " set-window-option -t " + pq + " window-size manual; " +
			b + " resize-window -t " + pq + " -x " + strconv.Itoa(cols) + " -y " + strconv.Itoa(rows)
	} else {
		inner = b + " set-window-option -t " + pq + " window-size latest"
	}
	_, err = t.runSSHTmux(ctx, inner)
	return err
}

// TmuxKill encerra o pane alvo (kill-pane): fecha o Claude que roda nele. Se for
// o último pane da janela/sessão do tmux, o próprio tmux fecha o resto em cascata.
func (t *SSHTarget) TmuxKill(ctx context.Context, target string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	_, err = t.runSSHTmux(ctx, tmuxBase(socket)+" kill-pane -t "+singleQuote(pane))
	return err
}

func (t *SSHTarget) TmuxSend(ctx context.Context, target, text string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	b, pq := tmuxBase(socket), singleQuote(pane)
	inner := b + " send-keys -t " + pq + " -l -- " + singleQuote(text) +
		"; " + b + " send-keys -t " + pq + " Enter"
	_, err = t.runSSHTmux(ctx, inner)
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
	socket, pane, err := parseTarget(target)
	if err != nil {
		return "", err
	}
	out, err := exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "capture-pane", "-t", pane, "-e", "-p", "-S", "-"+strconv.Itoa(tmuxScrollback))...).Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func (t *LocalTarget) TmuxKey(ctx context.Context, target, key string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	if !tmuxAllowedKeys[key] {
		return fmt.Errorf("claudecode: tecla não permitida: %q", key)
	}
	return exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "send-keys", "-t", pane, key)...).Run()
}

func (t *LocalTarget) TmuxResize(ctx context.Context, target string, cols, rows int) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	if cols > 0 && rows > 0 {
		_ = exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "set-window-option", "-t", pane, "window-size", "manual")...).Run()
		return exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "resize-window", "-t", pane, "-x", strconv.Itoa(cols), "-y", strconv.Itoa(rows))...).Run()
	}
	return exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "set-window-option", "-t", pane, "window-size", "latest")...).Run()
}

func (t *LocalTarget) TmuxKill(ctx context.Context, target string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	return exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "kill-pane", "-t", pane)...).Run()
}

func (t *LocalTarget) TmuxSend(ctx context.Context, target, text string) error {
	socket, pane, err := parseTarget(target)
	if err != nil {
		return err
	}
	if err := exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "send-keys", "-t", pane, "-l", "--", text)...).Run(); err != nil {
		return err
	}
	return exec.CommandContext(ctx, "tmux", tmuxLocalArgs(socket, "send-keys", "-t", pane, "Enter")...).Run()
}

// TmuxPaneAsDiscovered adapta um TmuxPane ao shape Discovered: id = alvo composto
// (socket\tpane), title = nome da sessão tmux com fallback pra última pasta do
// cwd quando o nome é auto-gerado (só dígitos) ou vazio.
func TmuxPaneAsDiscovered(p TmuxPane) session.Discovered {
	title := p.Session
	if title == "" || isAllDigits(title) {
		if base := lastPathComponent(p.Cwd); base != "" {
			title = base
		}
	}
	return session.Discovered{ID: p.ID, Cwd: p.Cwd, Title: title, State: p.State}
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
