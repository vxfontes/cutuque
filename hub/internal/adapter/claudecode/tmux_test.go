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

func TestValidTarget(t *testing.T) {
	for _, ok := range []string{"%0", "%12", "%9999"} {
		if err := validTarget(ok); err != nil {
			t.Errorf("validTarget(%q) = %v, quero nil", ok, err)
		}
	}
	for _, bad := range []string{"", "12", "%", "%1a", "$1", "%1; rm -rf ~", "%1 "} {
		if err := validTarget(bad); err == nil {
			t.Errorf("validTarget(%q) devia falhar", bad)
		}
	}
}
