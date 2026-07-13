// hub/internal/board/board_test.go
package board

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAddListUpdateRemove(t *testing.T) {
	s := New()
	a := s.Add("rodar testes", "interconexao", "cutuque")
	if a.ID == "" || a.Column != "a_fazer" {
		t.Fatalf("Add: id vazio ou coluna inicial errada: %+v", a)
	}
	if got := s.List(); len(got) != 1 {
		t.Fatalf("List: esperava 1, veio %d", len(got))
	}
	col := "em_progresso"
	u, ok := s.Update(a.ID, &col, nil)
	if !ok || u.Column != "em_progresso" {
		t.Fatalf("Update coluna falhou: ok=%v %+v", ok, u)
	}
	if !u.UpdatedAt.After(a.UpdatedAt) && !u.UpdatedAt.Equal(a.UpdatedAt) {
		t.Fatalf("UpdatedAt não avançou")
	}
	if _, ok := s.Update("inexistente", &col, nil); ok {
		t.Fatalf("Update de id inexistente deveria falhar")
	}
	if !s.Remove(a.ID) {
		t.Fatalf("Remove deveria retornar true")
	}
	if len(s.List()) != 0 {
		t.Fatalf("List após remove deveria ser 0")
	}
}

func TestValidColumn(t *testing.T) {
	for _, c := range Columns {
		if !ValidColumn(c) {
			t.Fatalf("ValidColumn(%q) deveria ser true", c)
		}
	}
	if ValidColumn("zzz") {
		t.Fatalf("ValidColumn(zzz) deveria ser false")
	}
}

func TestPersistLoad(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "board.json")
	s1 := NewAt(p)
	task := s1.Add("persistir", "g", "s")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("arquivo não foi escrito: %v", err)
	}
	s2 := NewAt(p)
	got := s2.List()
	if len(got) != 1 || got[0].ID != task.ID {
		t.Fatalf("não recarregou do disco: %+v", got)
	}
}
