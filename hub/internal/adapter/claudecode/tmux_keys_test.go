package claudecode

import "testing"

// A allowlist de teclas não é conveniência: no SSHTarget a tecla é concatenada
// CRUA no comando que roda no shell remoto (`send-keys -t 'pane' `+key). Ela é a
// única coisa entre o corpo de um POST e o shell da máquina da Vanessa — e até
// 16/08/2026 não tinha um único teste. Estes cobrem os dois lados: o que precisa
// passar, e o que nunca pode.

// TestTeclasDeComandoDaGavetaSaoPermitidas trava o contrato com a barra do app
// (TerminalKeyboard.letrasDeComando). Letra na barra sem letra aqui = botão que
// responde 502 calado, que é o modo de falha mais chato de diagnosticar.
func TestTeclasDeComandoDaGavetaSaoPermitidas(t *testing.T) {
	// Mesma lista, mesma ordem de TerminalKeyboard.letrasDeComando no app.
	for _, k := range []string{"j", "k", "x", "r", "p", "s"} {
		if !tmuxAllowedKeys[k] {
			t.Errorf("tecla %q da gaveta não está na allowlist", k)
		}
	}
}

// TestTeclasBasicasDoTerminalSaoPermitidas é a rede embaixo da barra antiga: se
// alguém reescrever o mapa e derrubar o Enter, o espelho inteiro para de digitar.
func TestTeclasBasicasDoTerminalSaoPermitidas(t *testing.T) {
	for _, k := range []string{"Enter", "Escape", "Tab", "C-c", "Up", "Down", "Left", "Right"} {
		if !tmuxAllowedKeys[k] {
			t.Errorf("tecla básica %q saiu da allowlist", k)
		}
	}
}

// TestAllowlistRecusaInjecaoDeShell é o teste que justifica a allowlist existir.
// Cada entrada aqui, se aceita, viraria comando na máquina remota — porque o
// valor vai sem aspas para dentro da linha do `ssh`.
func TestAllowlistRecusaInjecaoDeShell(t *testing.T) {
	perigosas := []string{
		"Enter; rm -rf /",       // encadeia um segundo comando
		"Enter && id",           // idem, com &&
		"$(id)",                 // substituição de comando
		"`id`",                  // substituição de comando, forma antiga
		"Enter | tee /tmp/x",    // pipe
		"'",                     // quebra o aspeamento do pane
		"Up Down",               // espaço vira segundo argumento do send-keys
		"\nEnter",               // nova linha vira comando novo
		"j&",                    // manda pro background
		"",                      // vazio: o handler já barra, o mapa também barra
	}
	for _, k := range perigosas {
		if tmuxAllowedKeys[k] {
			t.Errorf("allowlist aceitou %q — isso vira shell na máquina remota", k)
		}
	}
}

// TestAllowlistSoTemValorLiteralSimples garante que a própria lista não ganhe
// uma entrada perigosa por descuido: toda tecla permitida tem que ser um token
// sem espaço, aspa ou metacaractere de shell. É a barreira que sobrevive a quem
// adicionar tecla nova sem ler o comentário.
func TestAllowlistSoTemValorLiteralSimples(t *testing.T) {
	for k := range tmuxAllowedKeys {
		if k == "" {
			t.Error("allowlist tem entrada vazia")
			continue
		}
		for _, r := range k {
			ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-'
			if !ok {
				t.Errorf("tecla %q tem caractere %q que não é [A-Za-z0-9-]", k, r)
			}
		}
	}
}
