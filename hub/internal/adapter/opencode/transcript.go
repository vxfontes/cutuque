package opencode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

// transcriptScript lê o histórico de UMA sessão do OpenCode e emite a conversa
// como uma lista JSON de {kind,text}, no MESMO formato do parser ao vivo
// (parser.go), para o chat do app renderizar o recap igual ao stream:
//   - message role=user      + part type=text  -> kind "user"
//   - message role=assistant + part type=text  -> kind "assistant"
//   - part type=tool -> kind "tool" (nome + input, ≤120) + kind "tool_result" (state.output, ≤200)
//   - reasoning / step-start / step-finish -> ignorados
//
// Percorre message/<sid>/*.json ordenado por time.created e, para cada mensagem,
// suas partes em part/<msgID>/*.json ordenadas por time.start. Recebe o sid como
// argv[1] (python3 - <sid>). Mantém só os últimos 500 chunks (teto do registry).
const transcriptScript = `import os,json,glob,sys
sid=sys.argv[1] if len(sys.argv)>1 else ''
base=os.path.expanduser('~/.local/share/opencode/storage')
def trunc(s,n):
    s=str(s)
    return s if len(s)<=n else s[:n]
def tool_input(state):
    if not isinstance(state,dict): return ''
    inp=state.get('input')
    if isinstance(inp,dict):
        for k in ('filePath','command','pattern','path','query'):
            v=inp.get(k)
            if isinstance(v,str) and v: return trunc(v,120)
        return trunc(json.dumps(inp,ensure_ascii=False,separators=(',',':')),120)
    if isinstance(inp,str) and inp.strip(): return trunc(inp,120)
    return ''
out=[]
if sid:
    msgs=[]
    for mf in glob.glob(os.path.join(base,'message',sid,'*.json')):
        try: m=json.load(open(mf,errors='ignore'))
        except: continue
        mt=((m.get('time') or {}).get('created')) or 0
        msgs.append((mt,m.get('id',''),m.get('role','')))
    msgs.sort()
    for _,mid,role in msgs:
        parts=[]
        for pf in glob.glob(os.path.join(base,'part',mid,'*.json')):
            try: p=json.load(open(pf,errors='ignore'))
            except: continue
            pt=((p.get('time') or {}).get('start')) or 0
            parts.append((pt,p.get('id',''),p))
        parts.sort(key=lambda x:(x[0],x[1]))
        for _,_,p in parts:
            typ=p.get('type')
            if typ=='text':
                txt=p.get('text')
                if isinstance(txt,str) and txt.strip():
                    if role=='user': out.append({'kind':'user','text':txt})
                    elif role=='assistant': out.append({'kind':'assistant','text':txt})
            elif typ=='tool':
                name=p.get('tool') or 'ferramenta'
                d=tool_input(p.get('state'))
                out.append({'kind':'tool','text':name if not d else name+': '+d})
                st=p.get('state') or {}
                o=st.get('output')
                if isinstance(o,str) and o.strip():
                    out.append({'kind':'tool_result','text':trunc(o,200)})
print(json.dumps(out[-500:]))
`

// runTranscript executa o comando (python3 lendo o script pelo stdin, sid em
// argv[1]), captura o stdout e faz parse da lista JSON de chunks.
func runTranscript(cmd *exec.Cmd) ([]agent.TranscriptChunk, error) {
	cmd.Env = agent.ChildEnv()
	cmd.Stdin = strings.NewReader(transcriptScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return parseTranscript(out)
}

func parseTranscript(out []byte) ([]agent.TranscriptChunk, error) {
	out = []byte(strings.TrimSpace(string(out)))
	if len(out) == 0 {
		return nil, nil
	}
	var list []agent.TranscriptChunk
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, err
	}
	return list, nil
}

// Transcript lê o histórico da sessão id na máquina LOCAL.
func (t *LocalTarget) Transcript(ctx context.Context, id string) ([]agent.TranscriptChunk, error) {
	return runTranscript(exec.CommandContext(ctx, "python3", "-", id))
}

// Transcript lê o histórico da sessão id na máquina remota via ssh (python3 lá).
// id é single-quoted (defesa em profundidade — o launcher já o valida contra o
// sessionIDPattern antes de chegar aqui).
func (t *SSHTarget) Transcript(ctx context.Context, id string) ([]agent.TranscriptChunk, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+agent.SingleQuote(id))
	return runTranscript(exec.CommandContext(ctx, t.prog, args...))
}
