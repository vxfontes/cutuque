package claudecode

import (
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// estadoDaTela roda a parte PURA do script (tmuxStateFuncs) contra uma tela de
// fixture. É o que permite testar a inferência sem tmux: o `classify` não captura
// nada, recebe texto. Se o python3 do sistema não existir, o teste pula — o script
// remoto também depende dele, então não há o que garantir aqui.
func estadoDaTela(t *testing.T, tela, agente string) string {
	t.Helper()
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 ausente")
	}
	prog := tmuxStateFuncs + "\nimport sys\nprint(classify(sys.stdin.read()," + strconv.Quote(agente) + "))\n"
	cmd := exec.Command("python3", "-c", prog)
	cmd.Stdin = strings.NewReader(tela)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("python3 falhou: %v", err)
	}
	return strings.TrimSpace(string(out))
}

func TestClassifyClaude(t *testing.T) {
	casos := []struct {
		nome, tela, quer string
	}{
		{"trabalhando pelo timer vivo", telaClaudeTrabalhando, "running"},
		{"esperando no diálogo", telaClaudeEsperando, "waiting"},
		{"ociosa não casa com work_re", telaClaudeOciosa, "idle"},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			if got := estadoDaTela(t, c.tela, "claude"); got != c.quer {
				t.Fatalf("classify = %q, queria %q", got, c.quer)
			}
		})
	}
}
