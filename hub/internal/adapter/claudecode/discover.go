package claudecode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// discoverScript lê ~/.claude/projects/*/*.jsonl na máquina e emite JSON com as
// sessões do Claude Code existentes (id = nome do arquivo, cwd = campo cwd do
// transcript, title = primeira mensagem REAL do usuário, modified = mtime). Só
// inclui sessões com título (conversa real), descartando arquivos de estado.
// Pula mensagens sintéticas de slash-command (<local-command-caveat>,
// <command-name>...) e normaliza espaços em branco para um título limpo.
// Roda com o python3 do sistema (presente em macOS e no ZimaOS).
const discoverScript = `import os,json,glob
base=os.path.expanduser('~/.claude/projects')
def clean(t):
    t=' '.join(str(t).split())
    if not t: return ''
    for p in ('<local-command-caveat>','<command-','<task-notification>','[SYSTEM','Caveat:','<system-reminder>'):
        if t.startswith(p): return ''
    return t
def user_text(o):
    # devolve o texto real de uma mensagem de usuário, ou '' se sintética/vazia.
    if o.get('type')!='user': return ''
    m=o.get('message') or {}; c=m.get('content')
    if isinstance(c,str): return clean(c)
    if isinstance(c,list):
        for it in c:
            if isinstance(it,dict) and it.get('type')=='text':
                t=clean(it.get('text',''))
                if t: return t
    return ''
out=[]
for f in glob.glob(base+'/*/*.jsonl'):
    try:
        st=os.stat(f); sid=os.path.basename(f)[:-6]; cwd=''; title=''; last=''; count=0
        with open(f, errors='ignore') as fh:
            for line in fh:
                try: o=json.loads(line)
                except: continue
                if not cwd and isinstance(o.get('cwd'),str): cwd=o['cwd']
                t=user_text(o)
                if t:
                    count+=1
                    if not title: title=t
                    last=t
        if title:
            out.append({'id':sid,'cwd':cwd,'title':title[:100],'last':last[:200],'count':count,'modified':int(st.st_mtime)})
    except Exception: pass
out.sort(key=lambda x:-x['modified'])
print(json.dumps(out[:40]))
`

// Discoverer lista sessões do Claude Code já existentes numa máquina (inclusive
// as não lançadas pelo Cutuque). LocalTarget e SSHTarget o satisfazem.
type Discoverer interface {
	Discover(ctx context.Context) ([]session.Discovered, error)
}

// runDiscover executa o comando com o discoverScript.
func runDiscover(cmd *exec.Cmd) ([]session.Discovered, error) {
	return runDiscoverScript(cmd, discoverScript)
}

// runDiscoverScript executa o comando (python3 lendo o script dado pelo stdin),
// captura o stdout e faz parse da lista JSON de session.Discovered. Compartilhado
// por discover e live (mesmo shape de saída).
func runDiscoverScript(cmd *exec.Cmd, script string) ([]session.Discovered, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return parseDiscovered(out)
}

// parseDiscovered converte o JSON emitido pelo script em []session.Discovered.
func parseDiscovered(out []byte) ([]session.Discovered, error) {
	out = []byte(strings.TrimSpace(string(out)))
	if len(out) == 0 {
		return nil, nil
	}
	var list []session.Discovered
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, err
	}
	return list, nil
}

// Discover lista as sessões do Claude Code na máquina LOCAL.
func (t *LocalTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	return runDiscover(exec.CommandContext(ctx, "python3", "-"))
}

// Discover lista as sessões do Claude Code na máquina remota via ssh (roda
// python3 lá, lendo o script pelo stdin — reutiliza as mesmas opções de ssh).
func (t *SSHTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	return runDiscover(exec.CommandContext(ctx, t.prog, args...))
}
