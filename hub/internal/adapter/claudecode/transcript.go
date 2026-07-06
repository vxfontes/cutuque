package claudecode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
)

// transcriptScript lê o transcript de UMA sessão do Claude Code
// (~/.claude/projects/*/<id>.jsonl) e emite a conversa como uma lista JSON de
// {kind,text} no MESMO formato que o parser ao vivo produz (parser.go), para o
// chat do app renderizar o histórico igualzinho ao output em tempo real:
//   - texto do assistente  -> kind "assistant"
//   - tool_use             -> kind "tool"        ("Nome: comando/…", ≤120)
//   - tool_result          -> kind "tool_result" (texto, ≤200)
//   - mensagem do usuário  -> kind "user"        (pula caveats de slash-command)
//   - thinking             -> ignorado
//
// Recebe o id da sessão como argv[1] (python3 - <id>). Mantém só os últimos 500
// chunks (casa com o teto do registry). python3 do sistema (macOS e ZimaOS).
const transcriptScript = `import os,json,glob,sys
sid=sys.argv[1] if len(sys.argv)>1 else ''
def trunc(s,n):
    s=str(s)
    return s if len(s)<=n else s[:n]
def synthetic(t):
    t=str(t).lstrip()
    for p in ('<local-command-caveat>','<command-','<task-notification>','[SYSTEM','<system-reminder>'):
        if t.startswith(p): return True
    return False
def tool_summary(name,inp):
    name=name or 'ferramenta'
    detail=''
    if isinstance(inp,dict) and isinstance(inp.get('command'),str) and inp.get('command'):
        detail=trunc(inp['command'],120)
    elif inp is not None:
        detail=trunc(json.dumps(inp,ensure_ascii=False,separators=(',',':')),120)
    return name if not detail else name+': '+detail
def result_text(c):
    if isinstance(c,str): return c
    if isinstance(c,list):
        return ''.join(b.get('text','') for b in c if isinstance(b,dict))
    return ''
out=[]
matches=glob.glob(os.path.expanduser('~/.claude/projects/*/'+sid+'.jsonl'))
for f in matches[:1]:
    try:
        with open(f,errors='ignore') as fh:
            for line in fh:
                try: o=json.loads(line)
                except: continue
                t=o.get('type'); m=o.get('message') or {}; c=m.get('content')
                if t=='user':
                    if isinstance(c,str):
                        if c.strip() and not synthetic(c): out.append({'kind':'user','text':c})
                    elif isinstance(c,list):
                        for b in c:
                            if not isinstance(b,dict): continue
                            if b.get('type')=='text' and str(b.get('text','')).strip() and not synthetic(b.get('text','')):
                                out.append({'kind':'user','text':b['text']})
                            elif b.get('type')=='tool_result':
                                out.append({'kind':'tool_result','text':trunc(result_text(b.get('content')),200)})
                elif t=='assistant':
                    if isinstance(c,list):
                        for b in c:
                            if not isinstance(b,dict): continue
                            if b.get('type')=='text' and str(b.get('text','')).strip():
                                out.append({'kind':'assistant','text':b['text']})
                            elif b.get('type')=='tool_use':
                                out.append({'kind':'tool','text':tool_summary(b.get('name'),b.get('input'))})
    except Exception: pass
print(json.dumps(out[-500:]))
`

// runTranscript executa o comando (python3 lendo o script pelo stdin, com o id
// como argv[1]), captura o stdout e faz parse da lista JSON de chunks.
func runTranscript(cmd *exec.Cmd) ([]TranscriptChunk, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(transcriptScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return parseTranscript(out)
}

// parseTranscript converte o JSON emitido pelo script em []TranscriptChunk.
func parseTranscript(out []byte) ([]TranscriptChunk, error) {
	out = []byte(strings.TrimSpace(string(out)))
	if len(out) == 0 {
		return nil, nil
	}
	var list []TranscriptChunk
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, err
	}
	return list, nil
}

// Transcript lê o histórico da sessão id na máquina LOCAL.
func (t *LocalTarget) Transcript(ctx context.Context, id string) ([]TranscriptChunk, error) {
	return runTranscript(exec.CommandContext(ctx, "python3", "-", id))
}

// Transcript lê o histórico da sessão id na máquina remota via ssh (python3 lá,
// lendo o script pelo stdin, com o id como argv[1]). id é single-quoted (defesa
// em profundidade — Adopt já o valida contra ^[0-9a-fA-F-]{8,64}$).
func (t *SSHTarget) Transcript(ctx context.Context, id string) ([]TranscriptChunk, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(id))
	return runTranscript(exec.CommandContext(ctx, t.prog, args...))
}
