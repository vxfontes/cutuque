package claudecode

import (
	"strings"
	"testing"
)

func TestParseTmuxJSON(t *testing.T) {
	out := []byte(`[{"id":"%0","cmd":"claude","cwd":"/Users/example/proj","session":"work","window":"2.1.200"},{"id":"%3","cmd":"claude","cwd":"/tmp","session":"0","window":"zsh"}]`)
	panes := parseTmuxJSON(out)
	if len(panes) != 2 {
		t.Fatalf("len = %d, quero 2", len(panes))
	}
	if panes[0].ID != "%0" || panes[0].Session != "work" || panes[0].Cwd != "/Users/example/proj" {
		t.Errorf("pane[0] errado: %+v", panes[0])
	}
}

// TestParseTmuxJSONState: o campo state (lido do terminal) é preservado.
func TestParseTmuxJSONState(t *testing.T) {
	out := []byte(`[{"id":"%0","cmd":"claude","cwd":"/p","session":"a","window":"w","state":"running"},{"id":"%1","cmd":"claude","cwd":"/q","session":"b","window":"w","state":"idle"}]`)
	panes := parseTmuxJSON(out)
	if len(panes) != 2 || panes[0].State != "running" || panes[1].State != "idle" {
		t.Fatalf("state não preservado: %+v", panes)
	}
	// E vira Discovered.State para o app colorir.
	if d := TmuxPaneAsDiscovered(panes[0]); d.State != "running" {
		t.Errorf("Discovered.State = %q, quero running", d.State)
	}
}

func TestParseTmuxJSONEmpty(t *testing.T) {
	for _, in := range []string{"", "  ", "\n", "não-json"} {
		if got := parseTmuxJSON([]byte(in)); got != nil {
			t.Errorf("parseTmuxJSON(%q) = %v, quero nil", in, got)
		}
	}
}

// TestTmuxPaneAsDiscoveredTitle: nome de sessão nomeado vira título; sessão
// auto-nomeada (dígitos) cai na última pasta do cwd; a janela é ignorada.
func TestTmuxPaneAsDiscoveredTitle(t *testing.T) {
	cases := []struct {
		pane      TmuxPane
		wantTitle string
	}{
		{TmuxPane{ID: "%0", Cwd: "/Users/example/proj", Session: "work", Window: "2.1.200"}, "work"},
		{TmuxPane{ID: "%1", Cwd: "/Users/example/personal/cutuque", Session: "0", Window: "zsh"}, "cutuque"},
		{TmuxPane{ID: "%2", Cwd: "/tmp/", Session: "", Window: "x"}, "tmp"},
	}
	for _, c := range cases {
		got := TmuxPaneAsDiscovered(c.pane)
		if got.Title != c.wantTitle {
			t.Errorf("pane %+v → title %q, quero %q", c.pane, got.Title, c.wantTitle)
		}
		if got.ID != c.pane.ID || got.Cwd != c.pane.Cwd {
			t.Errorf("id/cwd não preservados: %+v", got)
		}
	}
}

func TestParseTarget(t *testing.T) {
	// pane simples (servidor default)
	if s, p, err := parseTarget("%12"); err != nil || s != "" || p != "%12" {
		t.Errorf("parseTarget(%%12) = (%q,%q,%v)", s, p, err)
	}
	// composto socket\tpane
	if s, p, err := parseTarget("/private/tmp/tmux-501/main\t%3"); err != nil || s != "/private/tmp/tmux-501/main" || p != "%3" {
		t.Errorf("parseTarget composto = (%q,%q,%v)", s, p, err)
	}
	// inválidos (pane ou socket fora do formato / injeção)
	for _, bad := range []string{"", "12", "%1a", "$1", "%1; rm -rf ~", "rel/path\t%1", "/x;rm\t%1"} {
		if _, _, err := parseTarget(bad); err == nil {
			t.Errorf("parseTarget(%q) devia falhar", bad)
		}
	}
}

func TestValidKillSocket(t *testing.T) {
	if validKillSocket("") == nil {
		t.Error("socket vazio devia ser rejeitado (não fechar o server default)")
	}
	if validKillSocket("/tmp/tmux-501/main") != nil {
		t.Error("socket válido foi rejeitado")
	}
	if validKillSocket("foo; rm -rf /") == nil {
		t.Error("socket com shell metachar devia ser rejeitado")
	}
}

// O kind vem do script (D11) e precisa atravessar até o Discovered — é o que
// permite o app mostrar o terminal vazio marcado em vez de escondê-lo.
func TestParseTmuxJSONKind(t *testing.T) {
	out := []byte(`[{"id":"/tmp/tmux-501/main\tpane1","cmd":"","kind":"shell","cwd":"/x","session":"s","window":"w","state":""}]`)
	panes := parseTmuxJSON(out)
	if len(panes) != 1 {
		t.Fatalf("panes = %d, queria 1", len(panes))
	}
	if panes[0].Kind != "shell" {
		t.Fatalf("Kind = %q, queria shell", panes[0].Kind)
	}
}

// Resposta de um script antigo (sem kind) não pode virar erro nem string aleatória:
// campo ausente é string vazia, e quem consome trata vazio como "agent".
func TestTmuxPaneAsDiscoveredKind(t *testing.T) {
	d := TmuxPaneAsDiscovered(TmuxPane{ID: "s\t%1", Cwd: "/x", Session: "sess", Kind: "shell"})
	if d.Kind != "shell" {
		t.Fatalf("Discovered.Kind = %q, queria shell", d.Kind)
	}
}

// BARREIRA (13/08/2026): todo comando tmux do hub tem que levar o -u. Sem ele o
// servidor sanitiza a saída dos formatos quando o cliente não anuncia UTF-8 e o
// TAB do alvo composto volta como "_" — foi assim que "novo terminal" criava a
// sessão e depois falhava. O bug não aparece em nenhum teste de unidade (é
// comportamento do tmux de verdade, com ambiente sem LANG), então o que sobra é
// travar a FORMA do comando aqui. Ver tmuxUTF8 em tmux.go.
// As asserções comparam com o literal "-u", NÃO com a constante: comparar com a
// constante deixaria passar quem trocasse o valor dela, que é exatamente a
// regressão a barrar.
func TestTodoComandoTmuxLevaUTF8(t *testing.T) {
	if tmuxUTF8 != "-u" {
		t.Fatalf("tmuxUTF8 = %q — o flag de UTF-8 do cliente tmux é -u", tmuxUTF8)
	}

	// 1) Caminho ssh: o -u vem imediatamente depois do "tmux", antes do -S.
	if got := tmuxBase(""); got != "tmux -u" {
		t.Errorf("tmuxBase(\"\") = %q, queria \"tmux -u\"", got)
	}
	if got := tmuxBase("/tmp/tmux-501/main"); got != "tmux -u -S '/tmp/tmux-501/main'" {
		t.Errorf("tmuxBase(socket) = %q", got)
	}

	// 2) Caminho local: primeiro arg do exec.Command("tmux", ...).
	for _, sock := range []string{"", "/tmp/tmux-501/main"} {
		args := tmuxLocalArgs(sock, "kill-server")
		if len(args) == 0 || args[0] != "-u" {
			t.Errorf("tmuxLocalArgs(%q) = %v, queria começar com -u", sock, args)
		}
	}

	// 3) Criação de sessão: é o comando cujo -F carrega o TAB, o que quebrou.
	spec, err := validarNovaSessao("defender", "mike", "/Users/vanessa/x", "terminal")
	if err != nil {
		t.Fatal(err)
	}
	if args := spec.localArgs(); len(args) == 0 || args[0] != "-u" {
		t.Errorf("localArgs = %v, queria começar com -u", args)
	}
	if inner := spec.sshInner(); !strings.HasPrefix(inner, "tmux -u ") {
		t.Errorf("sshInner = %q, queria prefixo \"tmux -u \"", inner)
	}

	// 4) Script da varredura: nenhuma chamada de tmux sem -u. Aqui o -u sobra
	//    hoje (o Python exporta LC_CTYPE=C.UTF-8 aos filhos, PEP 538), mas era
	//    exatamente esse acidente que fazia a varredura funcionar enquanto a
	//    criação falhava — depender dele de novo é o erro que este caso barra.
	chamadas := strings.Split(tmuxDriverScript, "run('tmux'")[1:]
	// Sem esta conferência o laço abaixo passaria VAZIO se alguém renomeasse o
	// run() — uma barreira que não roda é pior que barreira nenhuma.
	if len(chamadas) != 2 {
		t.Fatalf("achei %d chamadas de tmux no script, queria 2 (capture-pane e list-panes)", len(chamadas))
	}
	for i, resto := range chamadas {
		if !strings.HasPrefix(resto, ",'-u'") {
			t.Errorf("chamada de tmux nº %d no script sem -u: run('tmux'%.40s", i+1, resto)
		}
	}
}
