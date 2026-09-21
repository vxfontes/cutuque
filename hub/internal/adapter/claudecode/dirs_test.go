package claudecode

import "testing"

func TestParseDirListing(t *testing.T) {
	out := []byte(`{"path":"/Users/example","parent":"/Users","dirs":[{"name":"Desktop","path":"/Users/example/Desktop"},{"name":".maestri","path":"/Users/example/.maestri"}]}`)
	d, err := parseDirListing(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if d.Path != "/Users/example" || d.Parent != "/Users" || len(d.Dirs) != 2 {
		t.Fatalf("listing errado: %+v", d)
	}
	if d.Dirs[1].Name != ".maestri" {
		t.Errorf("pasta oculta não preservada: %+v", d.Dirs)
	}
}

// O seletor marca repositório por pasta e marca também a pasta atual — é ela
// que o "Usar esta" devolve. Hub antigo não emite `is_repo`; o parse tem de
// continuar funcionando e devolver false, nunca erro.
func TestParseDirListingMarcaRepositorio(t *testing.T) {
	out := []byte(`{"path":"/Users/example/code","parent":"/Users/example","is_repo":true,"dirs":[{"name":"cutuque","path":"/Users/example/code/cutuque","is_repo":true},{"name":"rascunhos","path":"/Users/example/code/rascunhos","is_repo":false}]}`)
	d, err := parseDirListing(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !d.IsRepo {
		t.Errorf("pasta atual devia vir marcada como repositório: %+v", d)
	}
	if !d.Dirs[0].IsRepo || d.Dirs[1].IsRepo {
		t.Errorf("marca por pasta errada: %+v", d.Dirs)
	}
}

func TestParseDirListingSemIsRepo(t *testing.T) {
	out := []byte(`{"path":"/Users/example","parent":"/Users","dirs":[{"name":"Desktop","path":"/Users/example/Desktop"}]}`)
	d, err := parseDirListing(out)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if d.IsRepo || d.Dirs[0].IsRepo {
		t.Errorf("sem o campo, nada pode vir marcado: %+v", d)
	}
}

func TestParseDirListingEmpty(t *testing.T) {
	d, err := parseDirListing([]byte("  "))
	if err != nil || len(d.Dirs) != 0 {
		t.Errorf("vazio devia dar listing vazio sem erro; got %+v err=%v", d, err)
	}
}
