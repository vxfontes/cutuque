package claudecode

import "testing"

// O opencode 1.18.16 escreve "esc interrupt" — SEM o "to" do Claude. A checagem
// que existia (`'esc to interrupt' in low`) não o pegava, e trocar por um
// `'interrupt' in low` genérico seria frágil: por isso o marcador é POR AGENTE.
func TestClassifyOpencodeTrabalhando(t *testing.T) {
	if got := estadoDaTela(t, telaOpencodeTrabalhando, "opencode"); got != "running" {
		t.Fatalf("classify = %q, queria running (marcador 'esc interrupt', sem o 'to')", got)
	}
}

// A armadilha: o opencode imprime a duração DEPOIS de concluir ("· 3.2s"). Quem
// afrouxar o work_re tirando a exigência do "\(" faz esta tela virar running para
// sempre. Este teste é a guarda.
func TestClassifyOpencodeOciosaNaoViraRunning(t *testing.T) {
	if got := estadoDaTela(t, telaOpencodeOciosa, "opencode"); got != "idle" {
		t.Fatalf("classify = %q, queria idle — a duração pós-conclusão não é timer vivo", got)
	}
}

// Agente fora da tabela continua neutro, como hoje: melhor sem bolinha do que com
// a bolinha errada.
func TestClassifyAgenteDesconhecidoEhNeutro(t *testing.T) {
	if got := estadoDaTela(t, telaClaudeTrabalhando, "gemini"); got != "" {
		t.Fatalf("classify = %q, queria vazio", got)
	}
}
