package server

import (
	"os/exec"
	"testing"
)

// TestParserAnsiDoDashboard roda o teste JS do parser ANSI dentro do `go test ./...`.
//
// [16/08/2026] O parser vive dentro de dashboard.html (embed, sem build step e sem
// <script src> — o dashboard não pode ter recurso externo), então quem o testa é um
// script node que EXTRAI o trecho por marcadores. Este wrapper existe só para que
// esse teste rode no mesmo gate que todo o resto (`make test`) em vez de depender de
// alguém lembrar de chamá-lo à mão.
//
// Pula quando não há node: o hub não tem node como dependência de build nem de
// execução, e um teste que só falha por causa do ambiente vira teste que se aprende
// a ignorar. A saída do t.Skip diz o comando exato para rodar manualmente.
func TestParserAnsiDoDashboard(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node ausente; rode manualmente: node hub/internal/server/dashboard_ansi_test.js")
	}

	out, err := exec.Command(node, "dashboard_ansi_test.js").CombinedOutput()
	if err != nil {
		t.Fatalf("parser ANSI do dashboard falhou: %v\n%s", err, out)
	}
}
