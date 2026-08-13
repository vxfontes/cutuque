package claudecode

import (
	"context"
	"strings"
	"testing"
)

func TestValidarNovaSessaoAgentes(t *testing.T) {
	casos := []struct{ agente, querCmd string }{
		{"claude", "claude"},
		// D10: o botão do codex copia o `tmx cx` — mesma flag, para app e terminal
		// darem a mesma coisa.
		{"codex", "codex --sandbox danger-full-access"},
		{"opencode", "opencode"},
		// D8: o terminal livre nasce sem agente nenhum, só o shell.
		{"terminal", ""},
	}
	for _, c := range casos {
		spec, err := validarNovaSessao("defender", "mike", "/Users/vanessa/x", c.agente)
		if err != nil {
			t.Fatalf("%s: erro inesperado: %v", c.agente, err)
		}
		if spec.Command != c.querCmd {
			t.Fatalf("%s: Command = %q, queria %q", c.agente, spec.Command, c.querCmd)
		}
	}
}

func TestValidarNovaSessaoRecusaNomeInvalido(t *testing.T) {
	// D12 é a camada de UX; esta é a defesa em profundidade. O tmux usa ":" e "."
	// como separador de alvo, e o socket viaja como caminho — nome com esses
	// caracteres viraria alvo ambíguo, não erro bonito.
	casos := [][2]string{
		{"defender:1", "mike"},
		{"defender", "mike.aux"},
		{"", "mike"},
		{"defender", ""},
		{"../etc", "mike"},
		{"defender", "mike aux"},
	}
	for _, c := range casos {
		if _, err := validarNovaSessao(c[0], c[1], "/Users/vanessa/x", "claude"); err == nil {
			t.Fatalf("grupo=%q sessão=%q: queria erro", c[0], c[1])
		}
	}
}

func TestValidarNovaSessaoRecusaPastaEAgente(t *testing.T) {
	if _, err := validarNovaSessao("defender", "mike", "relativo/x", "claude"); err == nil {
		t.Fatal("pasta relativa: queria erro")
	}
	if _, err := validarNovaSessao("defender", "mike", "/x", "gemini"); err == nil {
		t.Fatal("agente desconhecido: queria erro")
	}
}

func TestLocalArgsESshInner(t *testing.T) {
	spec, err := validarNovaSessao("defender", "mike", "/Users/vanessa/x", "codex")
	if err != nil {
		t.Fatal(err)
	}
	args := spec.localArgs()
	junto := strings.Join(args, " ")
	// -A anexa se a sessão já existir (não é erro: a spec diz que o app abre a aba
	// nela). -d não anexa o terminal do hub. -P -F devolve socket e pane. O -u vem
	// antes de tudo e é o que faz o TAB desse -F voltar inteiro (ver tmuxUTF8).
	for _, s := range []string{"-u -L defender", "new-session -A -d", "-s mike", "-c /Users/vanessa/x", "codex --sandbox danger-full-access"} {
		if !strings.Contains(junto, s) {
			t.Fatalf("localArgs sem %q: %v", s, args)
		}
	}
	if !strings.Contains(spec.sshInner(), "'codex --sandbox danger-full-access'") {
		t.Fatalf("sshInner sem o comando entre aspas: %s", spec.sshInner())
	}
}

func TestParseNovaSessao(t *testing.T) {
	// O socket vem como caminho; /private/tmp e /tmp são o MESMO dir no macOS, e a
	// varredura normaliza tirando o /private. Se a criação não normalizar igual, o
	// alvo devolvido não casa com nenhuma linha da lista ao vivo.
	got, err := parseNovaSessao([]byte("/private/tmp/tmux-501/defender\t%42\n"))
	if err != nil {
		t.Fatal(err)
	}
	if got != "/tmp/tmux-501/defender\t%42" {
		t.Fatalf("target = %q", got)
	}
	if _, err := parseNovaSessao([]byte("lixo")); err == nil {
		t.Fatal("saída sem tab: queria erro")
	}
	if _, err := parseNovaSessao([]byte("/tmp/tmux-501/x\tpane1")); err == nil {
		t.Fatal("pane fora do formato %N: queria erro")
	}
}

// Guarda de contrato: os dois targets satisfazem o Tmuxer com o método novo. Sem
// isto, só o handler quebraria — e bem mais tarde.
func TestTargetsImplementamTmuxNewSession(t *testing.T) {
	var _ Tmuxer = (*SSHTarget)(nil)
	var _ Tmuxer = (*LocalTarget)(nil)
}

// Nome inválido nem chega a virar comando: falha antes de qualquer I/O.
func TestTmuxNewSessionValidaAntesDeExecutar(t *testing.T) {
	var alvo LocalTarget
	if _, err := alvo.TmuxNewSession(context.Background(), "grupo:ruim", "s", "/x", "claude"); err == nil {
		t.Fatal("queria erro de validação")
	}
}
