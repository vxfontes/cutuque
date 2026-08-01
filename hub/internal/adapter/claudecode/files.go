package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// filesScript lista pastas E arquivos de um caminho na máquina, para o painel
// Arquivos da aba Máquinas. Recebe o caminho como argv[1] (vazio → home).
// Emite JSON:
//
//	{"path","parent","entries":[{"name","path","size","mtime","is_dir"}]}
//
// Pastas primeiro, depois arquivos, cada grupo em ordem case-insensitive — é a
// ordem que um navegador de arquivos deve ter. Inclui ocultos: o app decide
// esconder com um toggle, igual ao seletor de pastas.
//
// Entrada ilegível (permissão, link quebrado) é pulada em silêncio: uma pasta
// com um arquivo problemático precisa continuar navegável.
const filesScript = `import os,json,sys
base=sys.argv[1] if len(sys.argv)>1 and sys.argv[1] else os.path.expanduser('~')
base=os.path.abspath(base)
dirs=[];files=[]
try:
    for name in sorted(os.listdir(base),key=str.lower):
        p=os.path.join(base,name)
        try:
            st=os.stat(p)
            if os.path.isdir(p): dirs.append({'name':name,'path':p,'size':0,'mtime':int(st.st_mtime),'is_dir':True})
            else: files.append({'name':name,'path':p,'size':int(st.st_size),'mtime':int(st.st_mtime),'is_dir':False})
        except Exception: pass
except Exception: pass
print(json.dumps({'path':base,'parent':os.path.dirname(base),'entries':dirs+files}))
`

// runFiles executa o comando (python3 lendo o filesScript pelo stdin) e faz
// parse do JSON. Mesmo molde do runDirs.
func runFiles(cmd *exec.Cmd) (session.FileListing, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(filesScript)
	out, err := cmd.Output()
	if err != nil {
		return session.FileListing{}, err
	}
	return parseFileListing(out)
}

// parseFileListing converte o JSON emitido pelo script em session.FileListing.
// Saída vazia devolve listagem vazia sem erro.
func parseFileListing(out []byte) (session.FileListing, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.FileListing{}, nil
	}
	var fl session.FileListing
	if err := json.Unmarshal([]byte(s), &fl); err != nil {
		return session.FileListing{}, err
	}
	return fl, nil
}

// maxReadBytes é o teto de leitura como texto (1 MiB). Acima disso o script
// devolve truncated=true sem conteúdo: puxar um log de 2 GB para a memória do
// iPhone não é uma opção.
const maxReadBytes = 1048576

// readScriptFmt lê um arquivo de texto da máquina. Recebe o caminho como
// argv[1] e o teto de bytes por Sprintf (%d). Emite JSON:
//
//	{"path","size","binary","truncated","content"}
//
// Binário é detectado por byte nulo nos primeiros 8 KiB — o mesmo heurístico
// que o git usa. Binário e arquivo acima do teto voltam com content vazio.
// Arquivo ilegível não é erro: volta zerado, e o app mostra vazio em vez de
// derrubar a navegação.
const readScriptFmt = `import os,json,sys
p=os.path.abspath(sys.argv[1])
try: size=os.path.getsize(p)
except Exception: print(json.dumps({'path':p,'size':0,'binary':False,'truncated':False,'content':''})); sys.exit(0)
binary=False;truncated=False;content=''
try:
    with open(p,'rb') as f:
        if b'\x00' in f.read(8192): binary=True
    if not binary:
        if size > %d: truncated=True
        else:
            with open(p,'rb') as f: content=f.read().decode('utf-8','replace')
except Exception: pass
print(json.dumps({'path':p,'size':size,'binary':binary,'truncated':truncated,'content':content}))
`

// readScript devolve o script com o teto já embutido.
func readScript() string { return fmt.Sprintf(readScriptFmt, maxReadBytes) }

// runRead executa o comando (python3 lendo o readScript pelo stdin) e faz parse
// do JSON.
func runRead(cmd *exec.Cmd) (session.FileContent, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(readScript())
	out, err := cmd.Output()
	if err != nil {
		return session.FileContent{}, err
	}
	return parseFileContent(out)
}

// parseFileContent converte o JSON do readScript em session.FileContent.
func parseFileContent(out []byte) (session.FileContent, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.FileContent{}, nil
	}
	var fc session.FileContent
	if err := json.Unmarshal([]byte(s), &fc); err != nil {
		return session.FileContent{}, err
	}
	return fc, nil
}

// ListFiles lista pastas e arquivos de path na máquina LOCAL.
func (t *LocalTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, "python3", "-", path))
}

// ReadFile lê um arquivo na máquina LOCAL.
func (t *LocalTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	return runRead(exec.CommandContext(ctx, "python3", "-", path))
}

// listFilesArgs monta os args do ssh. Isolado do ListFiles para ser testável
// sem tocar a rede.
func (t *SSHTarget) listFilesArgs(path string) []string {
	return append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(path))
}

// ListFiles lista pastas e arquivos de path na máquina remota via ssh. path vai
// single-quoted como argumento — nunca interpolado no shell.
func (t *SSHTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, t.prog, t.listFilesArgs(path)...))
}

// ReadFile lê um arquivo na máquina remota via ssh. path vai single-quoted como
// argumento — nunca interpolado no shell.
func (t *SSHTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	args := append(sshBaseOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runRead(exec.CommandContext(ctx, t.prog, args...))
}
