package claudecode

import (
	"context"
	"os/exec"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// liveScript detecta as sessões do Claude Code que estão VIVAS agora numa
// máquina: há um processo `claude` rodando E o transcript foi escrito há pouco
// (janela de LIVE_WINDOW segundos). Combina duas evidências para ser preciso:
//   - processo: pega o session id de --session-id/--resume no argv quando existe
//     (sinal forte); senão, mapeia o cwd do processo (lsof) → .jsonl mais recente.
//   - recência: só mantém sessões cujo .jsonl mudou dentro da janela (descarta as
//     que já encerraram, mesmo com processo ainda no ar).
//
// Emite o MESMO shape do discover ([{id,cwd,title,last,count,modified}]), para o
// app reutilizar o mesmo modelo e o mesmo fluxo de preview/adoção.
const liveScript = `import os,json,glob,re,time,subprocess
UUID=r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
LIVE_WINDOW=180
now=time.time()
def clean(t):
    t=' '.join(str(t).split())
    if not t: return ''
    for p in ('<local-command-caveat>','<command-','<task-notification>','[SYSTEM','Caveat:','<system-reminder>'):
        if t.startswith(p): return ''
    return t
def user_text(o):
    if o.get('type')!='user': return ''
    m=o.get('message') or {}; c=m.get('content')
    if isinstance(c,str): return clean(c)
    if isinstance(c,list):
        for it in c:
            if isinstance(it,dict) and it.get('type')=='text':
                t=clean(it.get('text',''))
                if t: return t
    return ''
def procs():
    try:
        out=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True).stdout
    except Exception:
        return
    for line in out.splitlines():
        line=line.strip()
        if not line: continue
        pp=line.split(None,1)
        if len(pp)<2: continue
        pid,cmd=pp[0],pp[1]
        if 'daemon run' in cmd or 'bg-pty-host' in cmd or cmd.startswith('/bin/'): continue
        base=os.path.basename(cmd.split(None,1)[0])
        if not (('--session-id' in cmd) or base=='claude' or '/claude ' in cmd or cmd.startswith('claude')): continue
        yield pid,cmd
def cwd_of(pid):
    try:
        out=subprocess.run(['lsof','-a','-p',pid,'-d','cwd','-Fn'],capture_output=True,text=True,timeout=3).stdout
        for l in out.splitlines():
            if l.startswith('n'): return l[1:]
    except Exception: pass
    return ''
def sid_from_cmd(cmd):
    m=re.search(r'--session-id\s+('+UUID+')',cmd)
    if m: return m.group(1)
    m=re.search('('+UUID+r')\.jsonl',cmd)
    if m: return m.group(1)
    return ''
def newest_sid(cwd):
    if not cwd: return ''
    files=glob.glob(os.path.expanduser('~/.claude/projects/'+cwd.replace('/','-')+'/*.jsonl'))
    return os.path.basename(max(files,key=os.path.getmtime))[:-6] if files else ''
cands=set()
for pid,cmd in procs():
    sid=sid_from_cmd(cmd) or newest_sid(cwd_of(pid))
    if sid: cands.add(sid)
out=[]
for sid in cands:
    fs=glob.glob(os.path.expanduser('~/.claude/projects/*/'+sid+'.jsonl'))
    if not fs: continue
    f=fs[0]
    try: mt=os.path.getmtime(f)
    except Exception: continue
    if now-mt>LIVE_WINDOW: continue
    cwd='';title='';last='';count=0
    try:
        with open(f,errors='ignore') as fh:
            for line in fh:
                try: o=json.loads(line)
                except: continue
                if not cwd and isinstance(o.get('cwd'),str): cwd=o['cwd']
                t=user_text(o)
                if t:
                    count+=1
                    if not title: title=t
                    last=t
    except Exception: continue
    if title:
        out.append({'id':sid,'cwd':cwd,'title':title[:100],'last':last[:200],'count':count,'modified':int(mt)})
out.sort(key=lambda x:-x['modified'])
print(json.dumps(out))
`

// Live lista as sessões vivas na máquina LOCAL.
func (t *LocalTarget) Live(ctx context.Context) ([]session.Discovered, error) {
	return runDiscoverScript(exec.CommandContext(ctx, "python3", "-"), liveScript)
}

// Live lista as sessões vivas na máquina remota via ssh (python3 lá).
func (t *SSHTarget) Live(ctx context.Context) ([]session.Discovered, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	return runDiscoverScript(exec.CommandContext(ctx, t.prog, args...), liveScript)
}
