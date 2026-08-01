package claudecode

import (
	"context"
	"os/exec"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// liveScript detecta as sessões do Claude Code que estão VIVAS agora numa
// máquina: há um processo `claude` rodando E o transcript foi escrito há pouco
// (janela de LIVE_WINDOW segundos). Combina duas evidências para ser preciso:
//   - processo: pega o session id de --session-id/--resume/--fork-session no argv
//     quando existe (sinal forte); senão, mapeia o cwd do processo (lsof) → os N
//     .jsonl mais recentes daquela pasta, N = quantos processos sem flag estão
//     nela (dois `claude` no mesmo cwd são duas sessões, não uma).
//   - recência: poda por mtime, mas SÓ o que veio do palpite por cwd. Id lido do
//     argv é prova direta de que aquele processo roda aquela sessão — a mtime não
//     acrescenta nada e, aplicada ali, tirava da lista uma sessão viva parada num
//     comando longo (build, suíte inteira), que o reaper então mandava para idle
//     no meio do trabalho.
//
// A janela é generosa (15min) de propósito: quem estabelece a vida é o PROCESSO
// no ps; o mtime só desempata QUAL sessão daquele processo. Janela curta cortava
// sessão viva no meio de uma auto-compactação (medido: mediana 143s, cauda 270s)
// ou de uma tool call longa e silenciosa.
//
// Emite o MESMO shape do discover ([{id,cwd,title,last,count,modified}]), para o
// app reutilizar o mesmo modelo e o mesmo fluxo de preview/adoção.
const liveScript = `import os,json,glob,re,time,subprocess
UUID=r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
LIVE_WINDOW=900
now=time.time()
ANSI=re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]')
def clean(t):
    # Ver discover.go: mesma limpeza, e as duas tem que andar juntas — a mesma
    # sessao aparece na lista de adocao e na de vivas, com o mesmo titulo.
    t=' '.join(ANSI.sub('',str(t)).split())
    if not t: return ''
    for p in ('<local-command-','<command-','<task-notification>','[SYSTEM','Caveat:','<system-reminder>'):
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
    # SEM try/except de proposito. Engolir a falha do ps devolvia [] — que sai
    # daqui indistinguivel de "nenhuma sessao viva nesta maquina". O reaper le
    # esse [] como veredito e ceifa TODA sessao running da maquina. Deixar
    # estourar faz o script sair !=0, o Go recebe erro e a maquina inteira e
    # pulada no tick: "nao sei" nunca pode virar "morreu".
    out=subprocess.run(['ps','-axo','pid=,command='],capture_output=True,text=True,check=True).stdout
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
    # Mesmo criterio do procs(), so que por pid: distingue "esse processo nao
    # existe mais" de "nao consegui perguntar". Sair da funcao com '' esconde um
    # processo VIVO sem flag — justo o que nao tem outra evidencia — e o reaper
    # depois o ceifa. Entao o que e mesmo ignorancia sobe e derruba o script
    # inteiro (a maquina e pulada no tick); so o pid que sumiu vira ''.
    # Sem try: lsof travado (TimeoutExpired) ou ausente (FileNotFoundError) sobem.
    out=subprocess.run(['lsof','-a','-p',pid,'-d','cwd','-Fn'],capture_output=True,text=True,timeout=3).stdout
    for l in out.splitlines():
        if l.startswith('n'): return l[1:]
    # Sem linha n e sem excecao: lsof rodou e nao achou o pid. Ele saiu entre o
    # ps e o lsof — corrida normal, e isso E saber que nao esta mais la.
    return ''
def sid_from_cmd(cmd):
    m=re.search(r'--(?:session-id|resume|fork-session)\s+('+UUID+')',cmd)
    if m: return m.group(1)
    m=re.search('('+UUID+r')\.jsonl',cmd)
    if m: return m.group(1)
    return ''
def proj_dir(cwd):
    # O Claude Code troca TODO caractere fora de [A-Za-z0-9-] por '-' no nome da
    # pasta de transcript (ponto, underscore, espaco, acento). Trocar so '/'
    # errava toda sessao com ponto no caminho (.maestri/roles/...), que e
    # justamente onde ficam os agentes.
    return os.path.expanduser('~/.claude/projects/'+re.sub(r'[^A-Za-z0-9-]','-',cwd))
def recent_sids(cwd,n):
    # Os n transcripts mais recentes da pasta. Arquivo que sumiu entre o glob e
    # o stat e so um arquivo a menos (isso E "nao existe"), nao cega a varredura.
    fs=[]
    for f in glob.glob(proj_dir(cwd)+'/*.jsonl'):
        try: fs.append((os.path.getmtime(f),f))
        except OSError: pass
    fs.sort(reverse=True)
    return [os.path.basename(f)[:-6] for _,f in fs[:n]]
# Duas qualidades de candidato, e a diferenca importa la embaixo:
#   certos  — o id veio do argv do processo. Prova direta: ESTE processo esta
#             rodando ESTA sessao. Nao ha o que a mtime acrescente.
#   achados — o id foi adivinhado pelo cwd. So um palpite ordenado por recencia.
certos=set()
achados=set()
noflag={}
for pid,cmd in procs():
    sid=sid_from_cmd(cmd)
    if sid:
        certos.add(sid); continue
    # Sem id no argv o transcript so pode ser adivinhado pelo cwd. Conta quantos
    # processos assim ha em CADA pasta em vez de resolver um por um.
    c=cwd_of(pid)
    if c: noflag[c]=noflag.get(c,0)+1
for c,n in noflag.items():
    # n processos claude sem flag na MESMA pasta: eleger so o .jsonl mais
    # recente (o antigo max()) colapsava as n sessoes vivas em UMA — as outras
    # ficavam invisiveis aqui e o reaper as derrubava de running. Admite os n
    # mais recentes; a janela LIVE_WINDOW la embaixo poda quem ja encerrou.
    for sid in recent_sids(c,n): achados.add(sid)
achados-=certos
out=[]
for sid in certos|achados:
    fs=glob.glob(os.path.expanduser('~/.claude/projects/*/'+sid+'.jsonl'))
    if not fs: continue
    f=fs[0]
    try: mt=os.path.getmtime(f)
    except Exception: continue
    # A janela existe para podar PALPITE velho: n processos na pasta, os n
    # transcripts mais recentes, e entre eles pode vir o de uma sessao que ja
    # encerrou. Para id vindo do argv ela so atrapalha — a sessao esta viva por
    # prova direta, e transcript parado ha 15min e o que um comando longo
    # (build, suite inteira) produz. Podar ai apagava da lista uma sessao viva e
    # o reaper a mandava para idle no meio do trabalho.
    if sid in achados and now-mt>LIVE_WINDOW: continue
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
    # Sessao recem-aberta ainda nao tem mensagem de usuario. Ela esta VIVA (tem
    # processo no ps), entao nao pode sumir da lista: cai no nome da pasta.
    if not title: title=os.path.basename(cwd) or sid[:8]
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
	args := append(t.sshOpts(), "--", t.dest, "python3 -")
	return runDiscoverScript(exec.CommandContext(ctx, t.prog, args...), liveScript)
}
