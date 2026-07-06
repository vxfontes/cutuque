package agent

import (
	"context"

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

// DirLister lista subpastas de um caminho na máquina (seletor de pastas do app).
type DirLister interface {
	ListDirs(ctx context.Context, path string) (session.DirListing, error)
}

// Transcriber lê o histórico completo de UMA sessão numa máquina (para popular
// o output ao adotar / dar o recap).
type Transcriber interface {
	Transcript(ctx context.Context, id string) ([]TranscriptChunk, error)
}
