package opencode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// discoverScript lê o storage do OpenCode na máquina e emite as sessões
// existentes (inclusive as abertas fora do Cutuque), em paridade com o Codex.
//
// Layout (XDG default do opencode 1.x):
//
//	~/.local/share/opencode/storage/
//	  session/<projectID>/<sid>.json   -> id, directory (cwd), title, time.updated (ms)
//	  message/<sid>/<msgID>.json        -> role (user|assistant), time.created (ms)
//	  part/<msgID>/<prtID>.json         -> type text -> .text  (texto da mensagem)
//
// Para cada sessão: id/cwd/title vêm do session.json; `count` = nº de mensagens
// do usuário; `last` = texto da última mensagem do usuário (juntando as partes
// de texto). `modified` = time.updated (fallback: mtime do arquivo). Só inclui
// sessões com título (conversa real). Ordena por modified desc, top 40. Usa o
// python3 do sistema (mesma dependência do adapter do Codex).
const discoverScript = `import os,json,glob
base=os.path.expanduser('~/.local/share/opencode/storage')
def clean(t):
    return ' '.join(str(t).split())
def user_text(msgid):
    # concatena as partes type=text da mensagem (o texto do usuário mora nas parts).
    txt=[]
    for pf in sorted(glob.glob(os.path.join(base,'part',msgid,'*.json'))):
        try: p=json.load(open(pf,errors='ignore'))
        except: continue
        if p.get('type')=='text' and isinstance(p.get('text'),str):
            txt.append(p['text'])
    return clean(' '.join(txt))
out=[]
for sf in glob.glob(os.path.join(base,'session','*','ses_*.json')):
    try:
        s=json.load(open(sf,errors='ignore'))
    except: continue
    sid=s.get('id')
    if not isinstance(sid,str) or not sid: continue
    title=clean(s.get('title',''))
    cwd=s.get('directory','') if isinstance(s.get('directory'),str) else ''
    t=(s.get('time') or {})
    mod=t.get('updated') or t.get('created')
    try: mod=int(int(mod)//1000)
    except:
        try: mod=int(os.stat(sf).st_mtime)
        except: mod=0
    # mensagens do usuário (count + last + fallback de título).
    msgs=[]
    for mf in glob.glob(os.path.join(base,'message',sid,'*.json')):
        try: m=json.load(open(mf,errors='ignore'))
        except: continue
        if m.get('role')=='user':
            mt=((m.get('time') or {}).get('created')) or 0
            msgs.append((mt,m.get('id','')))
    msgs.sort()
    count=len(msgs); last=''
    if msgs:
        last=user_text(msgs[-1][1])
        if not title: title=user_text(msgs[0][1])
    if title:
        out.append({'id':sid,'cwd':cwd,'title':title[:100],'last':last[:200],'count':count,'modified':mod})
out.sort(key=lambda x:-x['modified'])
print(json.dumps(out[:40]))
`

func runDiscover(cmd *exec.Cmd) ([]session.Discovered, error) {
	cmd.Env = agent.ChildEnv()
	cmd.Stdin = strings.NewReader(discoverScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
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

// Discover lista as sessões do OpenCode na máquina LOCAL.
func (t *LocalTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	return runDiscover(exec.CommandContext(ctx, "python3", "-"))
}

// Discover lista as sessões do OpenCode na máquina remota via ssh (python3 lá).
func (t *SSHTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	return runDiscover(exec.CommandContext(ctx, t.prog, args...))
}
