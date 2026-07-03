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

func TestParseDirListingEmpty(t *testing.T) {
	d, err := parseDirListing([]byte("  "))
	if err != nil || len(d.Dirs) != 0 {
		t.Errorf("vazio devia dar listing vazio sem erro; got %+v err=%v", d, err)
	}
}
