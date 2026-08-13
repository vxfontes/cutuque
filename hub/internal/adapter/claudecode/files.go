package claudecode

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

// maxReadBytes é o teto de leitura como texto (1 MiB). Acima disso, texto não
// vem mais vazio (12/08/2026): vem a cauda (ver tailBytes). Só binário
// continua vindo vazio.
const maxReadBytes = 1048576

// tailBytes é o tamanho da cauda (200 KiB) devolvida no lugar do vazio quando
// um arquivo de TEXTO passa do maxReadBytes (12/08/2026) — é o pedaço que
// importa num log grande ("os arquivos de texto será que tem como..." — o
// pedido dela era não perder justo o fim). Curto o bastante para não pesar no
// app; bem maior que uma linha, para sobrar conteúdo depois de descartar a
// primeira linha (sempre parcial, ver readScriptFmt).
const tailBytes = 204800

// readScriptFmt lê um arquivo de texto da máquina. Recebe o caminho como
// argv[1], o teto de leitura e o teto da cauda por Sprintf (dois %d, NESTA
// ordem). Emite JSON:
//
//	{"path","size","binary","truncated","tail","content"}
//
// Binário é detectado por byte nulo nos primeiros 8 KiB — o mesmo heurístico
// que o git usa. Binário continua vindo com content vazio (o corte de binário
// é anterior a esta leva). Arquivo de TEXTO acima do teto de leitura NÃO volta
// mais vazio (12/08/2026): volta com os últimos `tailBytes` do arquivo,
// truncated=true E tail=true. A cauda começa DEPOIS da primeira quebra de
// linha encontrada no pedaço lido — um seek por byte quase nunca cai numa
// borda de linha, e a "linha" antes disso é só um fragmento do meio de uma
// linha real (podendo até cortar um caractere UTF-8 multibyte ao meio); melhor
// descartá-la que mostrar lixo como se fosse a primeira linha da cauda.
// Arquivo ilegível não é erro: volta zerado, e o app mostra vazio em vez de
// derrubar a navegação.
const readScriptFmt = `import os,json,sys
p=os.path.abspath(sys.argv[1])
try: size=os.path.getsize(p)
except Exception: print(json.dumps({'path':p,'size':0,'binary':False,'truncated':False,'tail':False,'content':''})); sys.exit(0)
binary=False;truncated=False;tail=False;content=''
try:
    with open(p,'rb') as f:
        if b'\x00' in f.read(8192): binary=True
    if not binary:
        if size > %d:
            truncated=True;tail=True
            with open(p,'rb') as f:
                f.seek(size-%d)
                raw=f.read()
            quebra=raw.find(b'\n')
            if quebra != -1: raw=raw[quebra+1:]
            content=raw.decode('utf-8','replace')
        else:
            with open(p,'rb') as f: content=f.read().decode('utf-8','replace')
except Exception: pass
print(json.dumps({'path':p,'size':size,'binary':binary,'truncated':truncated,'tail':tail,'content':content}))
`

// readScript devolve o script com os dois tetos já embutidos.
func readScript() string { return fmt.Sprintf(readScriptFmt, maxReadBytes, tailBytes) }

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

// ErrNotAFile é devolvido quando o caminho a salvar não existe ou não é um
// arquivo comum. A escrita SÓ sobrescreve arquivo existente (regra do spec):
// criar arquivo novo, ou escrever por cima de uma pasta, não é a mesma operação
// que "salvar o que abri".
var ErrNotAFile = errors.New("caminho não é um arquivo existente")

// writeScriptFmt salva um arquivo de texto na máquina. Recebe o caminho como
// argv[1]; o conteúdo vem embutido no PRÓPRIO script, em base64 (%s) — no argv
// um arquivo de 1 MB estouraria o ARG_MAX do macOS, e o stdin já está ocupado
// carregando o script. O alfabeto do base64 é seguro dentro de uma string
// Python, então não há o que escapar.
//
// Escreve em arquivo temporário no MESMO diretório e faz os.replace: uma queda
// no meio da gravação não pode deixar o arquivo da usuária truncado. O modo do
// original é preservado (o tempfile nasce 0600).
//
// Emite JSON: {"path","size","error"} — error vazio = salvou.
const writeScriptFmt = `import os,json,sys,base64,tempfile
p=os.path.abspath(sys.argv[1])
data=base64.b64decode('%s')
out={'path':p,'size':0,'error':''}
if not os.path.isfile(p):
    out['error']='not_a_file'
else:
    try:
        d=os.path.dirname(p)
        mode=os.stat(p).st_mode & 0o777
        fd,tmp=tempfile.mkstemp(dir=d)
        try:
            with os.fdopen(fd,'wb') as f: f.write(data)
            os.chmod(tmp,mode)
            os.replace(tmp,p)
        except Exception:
            try: os.unlink(tmp)
            except Exception: pass
            raise
        out['size']=os.path.getsize(p)
    except Exception:
        out['error']='write_failed'
print(json.dumps(out))
`

// writeScript devolve o script com o conteúdo já embutido em base64.
func writeScript(content []byte) string {
	return fmt.Sprintf(writeScriptFmt, base64.StdEncoding.EncodeToString(content))
}

// runWrite executa o comando (python3 lendo o writeScript pelo stdin) e faz
// parse do resultado.
func runWrite(cmd *exec.Cmd, content []byte) (session.FileWrite, error) {
	cmd.Env = childEnv()
	cmd.Stdin = strings.NewReader(writeScript(content))
	out, err := cmd.Output()
	if err != nil {
		return session.FileWrite{}, err
	}
	return parseFileWrite(out)
}

// parseFileWrite converte o JSON do writeScript, traduzindo o campo error em
// erro de Go. Saída vazia é erro: o python3 nem rodou, e dizer "salvo" sem ter
// salvo é pior do que falhar.
func parseFileWrite(out []byte) (session.FileWrite, error) {
	s := strings.TrimSpace(string(out))
	if s == "" {
		return session.FileWrite{}, errors.New("a máquina não respondeu ao salvar")
	}
	var r struct {
		Path  string `json:"path"`
		Size  int64  `json:"size"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(s), &r); err != nil {
		return session.FileWrite{}, err
	}
	switch r.Error {
	case "":
		return session.FileWrite{Path: r.Path, Size: r.Size}, nil
	case "not_a_file":
		return session.FileWrite{}, ErrNotAFile
	default:
		return session.FileWrite{}, fmt.Errorf("não deu para salvar em %s", r.Path)
	}
}

// ListFiles lista pastas e arquivos de path na máquina LOCAL.
func (t *LocalTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, "python3", "-", path))
}

// ReadFile lê um arquivo na máquina LOCAL.
func (t *LocalTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	return runRead(exec.CommandContext(ctx, "python3", "-", path))
}

// WriteFile salva um arquivo existente na máquina LOCAL.
func (t *LocalTarget) WriteFile(ctx context.Context, path string, content []byte) (session.FileWrite, error) {
	return runWrite(exec.CommandContext(ctx, "python3", "-", path), content)
}

// DownloadFile traz os bytes crus de um arquivo na máquina LOCAL, EM FLUXO. Usa
// cat em vez do python3: aqui não há nada para decidir, e cat não carrega o
// arquivo inteiro na memória do processo filho. Atualizado em 12/08/2026: o hub
// também parou de bufferizar (ver startDownload) — nem o cat nem o hub seguram
// um vídeo de 2 GB inteiro na memória a essa altura.
func (t *LocalTarget) DownloadFile(ctx context.Context, path string) (io.ReadCloser, error) {
	return startDownload(exec.CommandContext(ctx, "cat", "--", path))
}

// listFilesArgs monta os args do ssh. Isolado do ListFiles para ser testável
// sem tocar a rede.
func (t *SSHTarget) listFilesArgs(path string) []string {
	return append(t.sshOpts(), "--", t.dest, "python3 - "+singleQuote(path))
}

// ListFiles lista pastas e arquivos de path na máquina remota via ssh. path vai
// single-quoted como argumento — nunca interpolado no shell.
func (t *SSHTarget) ListFiles(ctx context.Context, path string) (session.FileListing, error) {
	return runFiles(exec.CommandContext(ctx, t.prog, t.listFilesArgs(path)...))
}

// ReadFile lê um arquivo na máquina remota via ssh. path vai single-quoted como
// argumento — nunca interpolado no shell.
func (t *SSHTarget) ReadFile(ctx context.Context, path string) (session.FileContent, error) {
	args := append(t.sshOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runRead(exec.CommandContext(ctx, t.prog, args...))
}

// WriteFile salva um arquivo existente na máquina remota via ssh. O caminho vai
// single-quoted no argv; o conteúdo vai no script, pelo stdin.
func (t *SSHTarget) WriteFile(ctx context.Context, path string, content []byte) (session.FileWrite, error) {
	args := append(t.sshOpts(), "--", t.dest, "python3 - "+singleQuote(path))
	return runWrite(exec.CommandContext(ctx, t.prog, args...), content)
}

// downloadArgs monta os args do ssh do download. Isolado para ser testável sem
// tocar a rede, igual ao listFilesArgs.
func (t *SSHTarget) downloadArgs(path string) []string {
	return append(t.sshOpts(), "--", t.dest, "cat -- "+singleQuote(path))
}

// DownloadFile traz os bytes crus de um arquivo na máquina remota via ssh, EM
// FLUXO (12/08/2026) — ver startDownload.
func (t *SSHTarget) DownloadFile(ctx context.Context, path string) (io.ReadCloser, error) {
	return startDownload(exec.CommandContext(ctx, t.prog, t.downloadArgs(path)...))
}

// downloadReadCloser adapta o StdoutPipe de um cmd (só Read; o Close dele
// fecha o descritor, mas NÃO espera o processo) a um io.ReadCloser que espera
// direito. Comum ao LocalTarget e ao SSHTarget — é o que faz o download em
// fluxo (ver startDownload).
type downloadReadCloser struct {
	pipe io.ReadCloser
	cmd  *exec.Cmd
}

func (d *downloadReadCloser) Read(p []byte) (int, error) { return d.pipe.Read(p) }

// Close fecha o pipe e SÓ DEPOIS espera o processo (cmd.Wait) — nessa ordem.
// Se o handler abandona a leitura antes do fim (a usuária saiu da tela, ou o
// io.Copy bateu num cliente que já desconectou), o cat/ssh pode estar preso no
// meio de uma escrita; fechar o pipe primeiro faz a próxima escrita dele bater
// num descritor fechado (EPIPE/SIGPIPE), o que o encerra — só então o Wait tem
// o que colher. SEM o Wait aqui, cada download deixaria um processo zumbi na
// tabela do macmini que roda o hub 24h (a Vanessa não reinicia o hub para
// limpar isso).
func (d *downloadReadCloser) Close() error {
	pipeErr := d.pipe.Close()
	waitErr := d.cmd.Wait()
	if pipeErr != nil {
		return pipeErr
	}
	return waitErr
}

// startDownload liga o stdout do cmd a um pipe e o inicia, devolvendo um
// io.ReadCloser que entrega os bytes conforme o processo produz — SEM
// acumular o arquivo inteiro na memória do hub primeiro (a mudança central
// desta leva: um arquivo grande virava o hub caindo, levando board, sessões e
// terminais junto). Quem chama TEM que fechar o resultado (defer) — ver
// downloadReadCloser.Close.
func startDownload(cmd *exec.Cmd) (io.ReadCloser, error) {
	cmd.Env = childEnv()
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &downloadReadCloser{pipe: pipe, cmd: cmd}, nil
}
