package codex

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

// transcriptScript lê o rollout de UMA sessão do Codex
// (~/.codex/sessions/AAAA/MM/DD/rollout-*-<id>.jsonl) e emite a conversa como uma
// lista JSON de {kind,text} no MESMO formato do parser ao vivo (parser.go), para
// o chat do app renderizar o histórico igual ao output em tempo real:
//   - event_msg/user_message   -> kind "user"
//   - event_msg/agent_message  -> kind "assistant"
//   - response_item/function_call        -> kind "tool"        (nome + cmd/args, ≤120)
//   - response_item/custom_tool_call     -> kind "tool"        (nome + input, ≤120)
//   - response_item/*_output             -> kind "tool_result" (saída, ≤200)
//   - reasoning / developer / task_* / token_count -> ignorados
//
// Mensagens vêm de event_msg (texto limpo, sem o system prompt "developer") e
// tools de response_item — fontes distintas, então não duplicam. Recebe o id
// como argv[1] (python3 - <id>). Mantém só os últimos 500 chunks (teto do registry).
const transcriptScript = `import os,json,glob,sys
sid=sys.argv[1] if len(sys.argv)>1 else ''
def trunc(s,n):
    s=str(s)
    return s if len(s)<=n else s[:n]
def arg_detail(a):
    d=None
    if isinstance(a,str):
        try: d=json.loads(a)
        except: d=None
    elif isinstance(a,dict): d=a
    if isinstance(d,dict):
        cmd=d.get('cmd') or d.get('command')
        if isinstance(cmd,list): cmd=' '.join(str(x) for x in cmd)
        if isinstance(cmd,str) and cmd: return trunc(cmd,120)
        return trunc(json.dumps(d,ensure_ascii=False,separators=(',',':')),120)
    if isinstance(a,str) and a.strip(): return trunc(a,120)
    return ''
def out_text(o):
    if isinstance(o,dict): o=o.get('content') or json.dumps(o,ensure_ascii=False)
    return trunc(o,200)
out=[]
matches=sorted(glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/rollout-*-'+sid+'.jsonl')))
for f in matches[:1]:
    try:
        with open(f,errors='ignore') as fh:
            for line in fh:
                try: o=json.loads(line)
                except: continue
                t=o.get('type'); p=o.get('payload') or {}
                if not isinstance(p,dict): continue
                pt=p.get('type')
                if t=='event_msg':
                    if pt=='user_message':
                        m=p.get('message')
                        if isinstance(m,str) and m.strip(): out.append({'kind':'user','text':m})
                    elif pt=='agent_message':
                        m=p.get('message')
                        if isinstance(m,str) and m.strip(): out.append({'kind':'assistant','text':m})
                elif t=='response_item':
                    if pt=='function_call':
                        name=p.get('name') or 'ferramenta'; d=arg_detail(p.get('arguments'))
                        out.append({'kind':'tool','text':name if not d else name+': '+d})
                    elif pt=='custom_tool_call':
                        name=p.get('name') or 'ferramenta'; d=trunc(p.get('input') or '',120)
                        out.append({'kind':'tool','text':name if not d else name+': '+d})
                    elif pt in ('function_call_output','custom_tool_call_output'):
                        out.append({'kind':'tool_result','text':out_text(p.get('output'))})
    except Exception: pass
print(json.dumps(out[-500:]))
`

// runTranscript executa o comando (python3 lendo o script pelo stdin, id em
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
// id é single-quoted (defesa em profundidade — o launcher já o valida contra
// ^[0-9a-fA-F-]{8,64}$ antes de chegar aqui).
func (t *SSHTarget) Transcript(ctx context.Context, id string) ([]agent.TranscriptChunk, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+agent.SingleQuote(id))
	return runTranscript(exec.CommandContext(ctx, t.prog, args...))
}
