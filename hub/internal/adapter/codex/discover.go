package codex

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// discoverScript lê os rollouts do Codex (~/.codex/sessions/AAAA/MM/DD/
// rollout-*-<uuid>.jsonl) na máquina e emite as sessões existentes: id = o uuid
// do nome do arquivo, cwd = do session_meta, title = 1ª user_message, modified =
// mtime. Só inclui sessões com título (conversa real). python3 do sistema.
const discoverScript = `import os,json,glob,re
base=os.path.expanduser('~/.codex/sessions')
uuid_re=re.compile(r'rollout-.*-([0-9a-fA-F-]{16,})\.jsonl$')
def clean(t):
    return ' '.join(str(t).split())
out=[]
for f in glob.glob(base+'/*/*/*/rollout-*.jsonl'):
    m=uuid_re.search(os.path.basename(f))
    if not m: continue
    sid=m.group(1)
    try:
        st=os.stat(f); cwd=''; title=''; last=''; count=0
        with open(f, errors='ignore') as fh:
            for line in fh:
                try: o=json.loads(line)
                except: continue
                t=o.get('type'); p=o.get('payload') or {}
                if not isinstance(p,dict): continue
                if not cwd and t=='session_meta' and isinstance(p.get('cwd'),str): cwd=p['cwd']
                if t=='event_msg' and p.get('type')=='user_message':
                    txt=clean(p.get('message',''))
                    if txt:
                        count+=1
                        if not title: title=txt
                        last=txt
        if title:
            out.append({'id':sid,'cwd':cwd,'title':title[:100],'last':last[:200],'count':count,'modified':int(st.st_mtime)})
    except Exception: pass
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

// Discover lista as sessões do Codex na máquina LOCAL.
func (t *LocalTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	return runDiscover(exec.CommandContext(ctx, "python3", "-"))
}

// Discover lista as sessões do Codex na máquina remota via ssh (python3 lá).
func (t *SSHTarget) Discover(ctx context.Context) ([]session.Discovered, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 -")
	return runDiscover(exec.CommandContext(ctx, t.prog, args...))
}
