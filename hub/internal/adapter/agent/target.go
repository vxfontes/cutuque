package agent

import (
	"context"
	"io"
	"os/exec"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Target é uma máquina/canal onde uma sessão de um agente é lançada e observada.
//
// Start dispara a sessão e devolve um Handle. resumeID != "" continua a conversa
// existente (mesmo id, preservando o contexto); vazio → sessão nova. cwd é a
// pasta onde o agente roda (vazio → home). model/effort são as escolhas do app
// (vazio → default do agente). prompt é o texto inicial:
//   - agentes bidirecionais (Claude): Start manda o prompt pelo stdin e o Handle
//     segue vivo para replies/aprovações;
//   - agentes one-shot (Codex `exec`): o prompt vai como argumento e o processo
//     sai ao fim do turno (cada reply é um novo Start com resumeID).
//
// Kind identifica o agente ("claude-code", "codex") — vira o campo Agent da
// sessão e valida o pedido de launch. NewRunner devolve o Runner com o parser e
// o rótulo certos para este agente.
// sandbox só é usado pelo Codex (read-only | workspace-write | danger-full-access);
// o Claude o ignora (o gate dele é o control_request de permissão). Vazio → o
// default do agente.
type Target interface {
	Name() string
	Kind() string
	Start(ctx context.Context, resumeID, cwd, model, effort, sandbox, prompt string) (*Handle, error)
	NewRunner(app Applier) *Runner
}

// TranscriptChunk é um pedaço do histórico lido de um transcript (recap).
type TranscriptChunk struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Discoverer lista as sessões do agente já existentes numa máquina (lendo o
// diretório de sessões do agente lá), inclusive as não lançadas pelo Cutuque.
type Discoverer interface {
	Discover(ctx context.Context) ([]session.Discovered, error)
}

// Liver lista as sessões do agente que estão RODANDO agora na máquina.
type Liver interface {
	Live(ctx context.Context) ([]session.Discovered, error)
}

// TranscriptLister lista os ids de TODAS as sessões que ainda têm transcript no
// disco da máquina. Diferente do Discoverer, não lê o conteúdo dos arquivos nem
// corta a lista: é a resposta EXATA para "essa sessão ainda existe lá?", que o
// reaper usa para decidir entre marcar idle e esquecer de vez.
type TranscriptLister interface {
	TranscriptIDs(ctx context.Context) ([]string, error)
}

// DirLister lista subpastas de um caminho na máquina (seletor de pastas do app).
type DirLister interface {
	ListDirs(ctx context.Context, path string) (session.DirListing, error)
}

// FileLister lista pastas E arquivos de um caminho na máquina (painel Arquivos
// da aba Máquinas). Opcional como o DirLister: só o adapter claude-code
// implementa, e o Launcher resolve por type assertion.
type FileLister interface {
	ListFiles(ctx context.Context, path string) (session.FileListing, error)
}

// FileReader lê um arquivo de texto na máquina (visualizador da aba Máquinas).
// Opcional, mesmo motivo do FileLister.
type FileReader interface {
	ReadFile(ctx context.Context, path string) (session.FileContent, error)
}

// FileWriter salva um arquivo de texto na máquina (editor da aba Máquinas).
// Opcional, mesmo motivo do FileLister. SÓ sobrescreve arquivo existente.
type FileWriter interface {
	WriteFile(ctx context.Context, path string, content []byte) (session.FileWrite, error)
}

// FileDownloader traz os bytes crus de um arquivo (download da aba Máquinas —
// inclusive binário, que o visualizador não mostra). Opcional, mesmo motivo.
//
// Devolve um io.ReadCloser, não []byte (12/08/2026): bufferizar o arquivo
// inteiro na memória do hub era a diferença entre atender um vídeo de 2 GB e o
// hub cair levando board, sessões e terminais junto. Quem chama TEM que fechar
// (defer) — é o Close() que espera o processo (cat/ssh) e evita zumbi; ver
// claudecode.startDownload.
type FileDownloader interface {
	DownloadFile(ctx context.Context, path string) (io.ReadCloser, error)
}

// ShellDialer monta o comando de um shell interativo na máquina (terminal livre
// da aba Máquinas). Opcional como o FileLister: só os alvos por ssh
// implementam — a máquina "local" é o próprio hub, e abrir um shell dentro do
// container não é a mesma coisa que entrar numa máquina.
//
// Devolve o comando montado, e não os args crus, porque o ambiente do filho é
// parte do contrato: sem HOME o `ssh` não acha nem a config nem as chaves.
type ShellDialer interface {
	ShellCommand(ctx context.Context) *exec.Cmd
}

// Transcriber lê o histórico completo de UMA sessão numa máquina (para popular
// o output ao adotar / dar o recap).
type Transcriber interface {
	Transcript(ctx context.Context, id string) ([]TranscriptChunk, error)
}
