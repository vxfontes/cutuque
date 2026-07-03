package claudecode

import "testing"

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
