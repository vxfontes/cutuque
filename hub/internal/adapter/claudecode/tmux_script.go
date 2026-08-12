package claudecode

// tmuxStateFuncs é a parte PURA do script de varredura: recebe a tela do pane como
// texto e devolve o estado. Vive separada do driver por dois motivos — é a única
// parte que dá para testar sem tmux (ver tmux_script_test.go), e é a que muda
// quando uma TUI de agente muda de string.
//
// Estados:
//   - 'running' : trabalhando agora. Sinal principal = o TIMER VIVO do spinner
//                 entre parênteses ("(8s" / "(4m 18s"), que aparece enquanto gera
//                 ou roda ferramenta e some ao ficar ocioso. "esc to interrupt"
//                 NÃO aparece no modo bypass-permissions do Claude, então não dá
//                 para depender só dele; "agent(s) to finish" = espera subagente.
//   - 'waiting' : parado num diálogo de permissão/escolha ("Do you want to...").
//   - 'idle'    : ocioso no prompt = concluiu o turno (o "concluído" → verde).
//
// O "\(" do work_re NÃO é detalhe: o status ocioso do Claude é passado
// ("Cogitated for 10s") e o opencode imprime a duração DEPOIS de concluir
// ("▣ Build · <modelo> · 3.2s"). Sem o parêntese, as duas telas ociosas viram
// 'running' para sempre. Não afrouxe — há teste para isso.
const tmuxStateFuncs = `import re
work_re=re.compile(r'\((?:\d+m )?\d+s')
def classify(txt,agent):
    low=txt.lower()
    if work_re.search(txt) or 'esc to interrupt' in low or 'agent to finish' in low or 'agents to finish' in low:
        return 'running'
    if 'do you want to proceed' in low or 'do you want to make this edit' in low:
        return 'waiting'
    return 'idle'
`

// tmuxDriverScript lista os panes do tmux (de TODOS os servidores, inclusive os
// nomeados via `-L`, pois o tmx.sh da usuária agrupa por servidor) e mantém só
// os que têm um `claude` na ÁRVORE DE PROCESSOS do pane — robusto contra o nome
// do binário (`versions/<semver>`) e contra flicker (claude spawna `bash`).
// Emite [{id,socket,pane,cmd,cwd,session,window}] onde id = "<socket>\t<pane>"
// (alvo composto: pane_id só é único DENTRO de um servidor). python3 do sistema.
const tmuxDriverScript = `import subprocess,json,os,re,glob
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
def agent_of(root):
    # Qual agente roda na árvore de processos do pane ('claude'|'codex'|
    # 'opencode') ou '' se nenhum. Cobertura universal do fallback tmux: qualquer
    # um dos três aparece e pode ser espelhado/digitado (capture/send-keys são
    # agnósticos). O estado do terminal só é inferido pro Claude (ver pane_state).
    seen=set(); stack=[root]
    while stack:
        p=stack.pop()
        if p in seen: continue
        seen.add(p)
        c=cmd.get(p,'').lower()
        if 'daemon' not in c and 'bg-pty-host' not in c:
            if 'claude' in c: return 'claude'
            if 'codex' in c: return 'codex'
            if 'opencode' in c: return 'opencode'
        stack+=kids.get(p,[])
    return ''
def norm(x):
    # /tmp e /private/tmp são o mesmo dir no macOS (symlink); normaliza pra uma
    # forma só, senão o mesmo socket apareceria duas vezes e não casaria com o
    # socket que o hook reporta.
    return x[len('/private'):] if x.startswith('/private/') else x
def pane_state(sock,pane,agent):
    # Lê a tela visível do pane e delega a classificação para classify (parte pura).
    return classify(run('tmux','-S',sock,'capture-pane','-t',pane,'-p'),agent)
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
        ag=agent_of(pid)
        if not ag: continue
        # Estado real só é confiável pro Claude (os marcadores da TUI são dele);
        # pro Codex/OpenCode deixamos '' (neutro) — o espelho mostra a tela de
        # verdade e não arriscamos rotular um estado errado.
        st=pane_state(sock,f[0],ag) if ag=='claude' else ''
        out.append({'id':sock+'\t'+f[0],'socket':sock,'pane':f[0],'cmd':ag,'cwd':f[2],'session':f[3],'window':f[4],'state':st})
print(json.dumps(out))
`

// tmuxListScript é o que roda de fato na máquina remota (via `python3 -`): as
// funções puras mais o driver que varre os servidores. Concatenado, e não um
// arquivo único, porque só a primeira metade é testável isoladamente.
const tmuxListScript = tmuxStateFuncs + tmuxDriverScript
