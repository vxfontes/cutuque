package claudecode

import "testing"

// O codex 0.147.0 funciona com os marcadores do Claude: a tela real de trabalho é
// "• Working (29s • esc to interrupt)" — timer vivo confirmado (29s → 31s → 33s em
// leituras de 2s). Estes dois travam a linha do codex na tabela.
func TestClassifyCodexTrabalhandoEOciosa(t *testing.T) {
	if got := estadoDaTela(t, telaCodexTrabalhando, "codex"); got != "running" {
		t.Fatalf("trabalhando: classify = %q, queria running", got)
	}
	if got := estadoDaTela(t, telaCodexOciosa, "codex"); got != "idle" {
		t.Fatalf("ociosa: classify = %q, queria idle", got)
	}
}

// Travado no portão de confiança NÃO é concluído. Sem isto, a Vanessa vê bolinha
// verde numa sessão que não vai andar até alguém apertar 1.
func TestClassifyCodexPortaoDeConfiancaEhWaiting(t *testing.T) {
	if got := estadoDaTela(t, telaCodexPortaoDeConfianca, "codex"); got != "waiting" {
		t.Fatalf("classify = %q, queria waiting — a sessão está travada esperando tecla", got)
	}
}
