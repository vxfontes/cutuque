package claudecode

import (
	"strings"
	"testing"
)

// D11: o pane sem agente deixa de ser descartado e passa a sair marcado como
// "shell". Guarda no conteúdo do driver — ele não roda em teste unitário.
func TestDriverMantemShellMarcado(t *testing.T) {
	if strings.Contains(tmuxDriverScript, "if not ag: continue") {
		t.Fatal("o driver ainda descarta pane sem agente; D11 pede que ele apareça marcado")
	}
	for _, s := range []string{"'kind':kind", "kind='agent' if ag else 'shell'"} {
		if !strings.Contains(tmuxDriverScript, s) {
			t.Fatalf("driver sem %q", s)
		}
	}
}
