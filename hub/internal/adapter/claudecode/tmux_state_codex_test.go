package claudecode

import (
	"strings"
	"testing"
)

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

// O driver precisa inferir estado para TODO agente detectado. O portão original
// existia porque os marcadores do codex/opencode não eram conhecidos — passaram a
// ser, calibrados por captura em 12/08/2026 (ver tmux_screens_test.go).
func TestDriverNaoRestringeEstadoAoClaude(t *testing.T) {
	if strings.Contains(tmuxDriverScript, "if ag=='claude'") {
		t.Fatal("o portão que limitava o estado ao Claude voltou ao driver")
	}
	if !strings.Contains(tmuxDriverScript, "st=pane_state(sock,f[0],ag)") {
		t.Fatal("o driver precisa passar o agente para pane_state")
	}
}
