package claudecode

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// dirsScript lista as SUBPASTAS imediatas de um caminho na máquina, para o
// seletor de pastas do app (criar sessão numa pasta escolhida em vez de digitar
// o cwd; escolher o repositório do painel Diff). Recebe o caminho como argv[1]
// (vazio → home da máquina). Emite JSON:
//
//	{"path":"<abs>", "parent":"<abs do pai>", "is_repo":<bool>,
//	 "dirs":[{"name","path","is_repo"},...]}
//
// Inclui pastas ocultas (as que começam com "."): o app decide esconder/mostrar
// com um toggle. Ordena case-insensitive. python3 do sistema (macOS e ZimaOS).
// O caminho chega como argv (nunca interpolado no shell) — sem risco de injeção.
//
// [20/09/2026] `is_repo` nasceu com o painel Diff passando a escolher a pasta
// pelo seletor: sem marca, achar o repositório é descer às cegas. O teste é
// `os.path.exists` no `.git` — e é exists, não isdir, de propósito: em worktree
// e em submódulo o `.git` é um ARQUIVO apontando para o repositório de verdade,
// e esses continuam sendo pastas onde `git diff` responde. Custo: um stat a
// mais por entrada, no mesmo processo remoto que já roda.
const dirsScript = `import os,json,sys
base=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else os.path.expanduser('~')
base=os.path.abspath(base)
def is_repo(d):
    try: return os.path.exists(os.path.join(d,'.git'))
    except Exception: return False
out=[]
try:
    for name in sorted(os.listdir(base),key=str.lower):
        p=os.path.join(base,name)
        try:
            if os.path.isdir(p): out.append({'name':name,'path':p,'is_repo':is_repo(p)})
        except Exception: pass
except Exception: pass
print(json.dumps({'path':base,'parent':os.path.dirname(base),'is_repo':is_repo(base),'dirs':out}))
`

// runDirs executa o comando (python3 lendo o dirsScript pelo stdin, caminho como
// argv[1]), captura o stdout e faz parse do JSON.
func runDirs(cmd *exec.Cmd) (session.DirListing, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(dirsScript)
	out, err := cmd.Output()
	if err != nil {
		return session.DirListing{}, err
	}
	return parseDirListing(out)
}

// parseDirListing converte o JSON emitido pelo script em session.DirListing.
func parseDirListing(out []byte) (session.DirListing, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.DirListing{}, nil
	}
	var d session.DirListing
	if err := json.Unmarshal([]byte(s), &d); err != nil {
		return session.DirListing{}, err
	}
	return d, nil
}

// ListDirs lista as subpastas de path na máquina LOCAL.
func (t *LocalTarget) ListDirs(ctx context.Context, path string) (session.DirListing, error) {
	return runDirs(exec.CommandContext(ctx, "python3", "-", path))
}

// ListDirs lista as subpastas de path na máquina remota via ssh (python3 lá,
// lendo o script pelo stdin, com o caminho como argv[1]). path é single-quoted
// (defesa em profundidade — vai como argumento, não é interpolado no shell).
func (t *SSHTarget) ListDirs(ctx context.Context, path string) (session.DirListing, error) {
	args := append(t.sshOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runDirs(exec.CommandContext(ctx, t.prog, args...))
}
