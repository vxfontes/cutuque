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
// o cwd). Recebe o caminho como argv[1] (vazio → home da máquina). Emite JSON:
//
//	{"path":"<abs>", "parent":"<abs do pai>", "dirs":[{"name","path"},...]}
//
// Inclui pastas ocultas (as que começam com "."): o app decide esconder/mostrar
// com um toggle. Ordena case-insensitive. python3 do sistema (macOS e ZimaOS).
// O caminho chega como argv (nunca interpolado no shell) — sem risco de injeção.
const dirsScript = `import os,json,sys
base=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else os.path.expanduser('~')
base=os.path.abspath(base)
out=[]
try:
    for name in sorted(os.listdir(base),key=str.lower):
        p=os.path.join(base,name)
        try:
            if os.path.isdir(p): out.append({'name':name,'path':p})
        except Exception: pass
except Exception: pass
print(json.dumps({'path':base,'parent':os.path.dirname(base),'dirs':out}))
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
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runDirs(exec.CommandContext(ctx, t.prog, args...))
}
