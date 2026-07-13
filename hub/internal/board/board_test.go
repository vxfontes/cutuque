// hub/internal/board/board_test.go
package board

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAddListUpdateRemove(t *testing.T) {
	s := New()
	a := s.Add(NewTask{Title: "rodar testes", Group: "interconexao", Session: "cutuque", Type: "claude"})
	if a.ID == "" || a.Column != "a_fazer" {
		t.Fatalf("Add: id vazio ou coluna inicial errada: %+v", a)
	}
	if got := s.List(); len(got) != 1 {
		t.Fatalf("List: esperava 1, veio %d", len(got))
	}
	col := "em_progresso"
	u, ok := s.Update(a.ID, &col, nil, nil, nil)
	if !ok || u.Column != "em_progresso" {
		t.Fatalf("Update coluna falhou: ok=%v %+v", ok, u)
	}
	if !u.UpdatedAt.After(a.UpdatedAt) && !u.UpdatedAt.Equal(a.UpdatedAt) {
		t.Fatalf("UpdatedAt não avançou")
	}
	if _, ok := s.Update("inexistente", &col, nil, nil, nil); ok {
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
	task := s1.Add(NewTask{Title: "persistir", Group: "g", Session: "s"})
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("arquivo não foi escrito: %v", err)
	}
	s2 := NewAt(p)
	got := s2.List()
	if len(got) != 1 || got[0].ID != task.ID {
		t.Fatalf("não recarregou do disco: %+v", got)
	}
}

func TestTimelineCommentsDescRole(t *testing.T) {
	s := New()
	a := s.Add(NewTask{Title: "x", Group: "g", Session: "s", Type: "claude", Role: "marcus", Description: "fazer X"})
	if a.Role != "marcus" || a.Description != "fazer X" {
		t.Fatalf("Add não gravou role/description: %+v", a)
	}
	prog, rev, done := "em_progresso", "em_revisao", "concluido"
	u, _ := s.Update(a.ID, &prog, nil, nil, nil)
	if u.StartedAt == nil {
		t.Fatalf("StartedAt deveria ser setado em em_progresso")
	}
	u, _ = s.Update(a.ID, &rev, nil, nil, nil)
	if u.ReviewedAt == nil {
		t.Fatalf("ReviewedAt deveria ser setado em em_revisao")
	}
	u, _ = s.Update(a.ID, &done, nil, nil, nil)
	if u.EndedAt == nil {
		t.Fatalf("EndedAt deveria ser setado em concluido")
	}
	// description/role via Update
	nd, nr := "nova desc", "ludmilla"
	u, _ = s.Update(a.ID, nil, nil, &nd, &nr)
	if u.Description != "nova desc" || u.Role != "ludmilla" {
		t.Fatalf("Update desc/role falhou: %+v", u)
	}
	// comentários
	c, ok := s.AddComment(a.ID, "marcus", "comecei o trabalho")
	if !ok || len(c.Comments) != 1 || c.Comments[0].Author != "marcus" || c.Comments[0].Text != "comecei o trabalho" {
		t.Fatalf("AddComment falhou: ok=%v %+v", ok, c.Comments)
	}
	if _, ok := s.AddComment("inexistente", "x", "y"); ok {
		t.Fatalf("AddComment em id inexistente deveria falhar")
	}
}
