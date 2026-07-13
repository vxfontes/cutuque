// hub/internal/board/board_test.go
package board

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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
	u, ok := s.Update(a.ID, &col, nil, nil, nil, "")
	if !ok || u.Column != "em_progresso" {
		t.Fatalf("Update coluna falhou: ok=%v %+v", ok, u)
	}
	if !u.UpdatedAt.After(a.UpdatedAt) && !u.UpdatedAt.Equal(a.UpdatedAt) {
		t.Fatalf("UpdatedAt não avançou")
	}
	if _, ok := s.Update("inexistente", &col, nil, nil, nil, ""); ok {
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
	u, _ := s.Update(a.ID, &prog, nil, nil, nil, "")
	if u.StartedAt == nil {
		t.Fatalf("StartedAt deveria ser setado em em_progresso")
	}
	u, _ = s.Update(a.ID, &rev, nil, nil, nil, "")
	if u.ReviewedAt == nil {
		t.Fatalf("ReviewedAt deveria ser setado em em_revisao")
	}
	u, _ = s.Update(a.ID, &done, nil, nil, nil, "")
	if u.EndedAt == nil {
		t.Fatalf("EndedAt deveria ser setado em concluido")
	}
	// description/role via Update
	nd, nr := "nova desc", "ludmilla"
	u, _ = s.Update(a.ID, nil, nil, &nd, &nr, "")
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

func TestSetEncalhada(t *testing.T) {
	s := New()
	a := s.Add(NewTask{Title: "marcar manual", Group: "g", Session: "s"})
	u, ok := s.SetEncalhada(a.ID, true, "")
	if !ok || !u.Encalhada {
		t.Fatalf("SetEncalhada(true) falhou: ok=%v %+v", ok, u)
	}
	// mover limpa a marca
	col := "em_progresso"
	u, _ = s.Update(a.ID, &col, nil, nil, nil, "")
	if u.Encalhada {
		t.Fatalf("mover deveria limpar encalhada")
	}
	if _, ok := s.SetEncalhada("inexistente", true, ""); ok {
		t.Fatalf("SetEncalhada em id inexistente deveria falhar")
	}
}

func TestSearch(t *testing.T) {
	s := New()
	a := s.Add(NewTask{Title: "corrigir login OAuth", Group: "g", Session: "s", Description: "refresh token"})
	s.Add(NewTask{Title: "outra coisa", Group: "g", Session: "s"})
	c := s.Add(NewTask{Title: "card com comentario", Group: "g", Session: "s"})
	s.AddComment(c.ID, "marcus", "isso tem a palavra OAuth no comentario")
	// arquiva um card concluído que casa
	done := s.Add(NewTask{Title: "feito OAuth antigo", Group: "g", Session: "s"})
	col := "concluido"
	s.Update(done.ID, &col, nil, nil, nil, "")
	s.CloseWeek(time.Now())

	res := s.Search("oauth")
	ids := map[string]bool{}
	for _, r := range res {
		ids[r.ID] = true
	}
	if !ids[a.ID] {
		t.Fatalf("deveria achar por título")
	}
	if !ids[c.ID] {
		t.Fatalf("deveria achar por comentário")
	}
	if !ids[done.ID] {
		t.Fatalf("deveria achar no arquivo")
	}
	// o arquivado vem com Archived=true
	for _, r := range res {
		if r.ID == done.ID && !r.Archived {
			t.Fatalf("card arquivado deveria ter Archived=true")
		}
	}
	if len(s.Search("")) != 0 {
		t.Fatalf("busca vazia deveria retornar nada")
	}
}

func TestActivityLog(t *testing.T) {
	s := New()
	a := s.Add(NewTask{Title: "x", Group: "g", Session: "s", Role: "marcus"})
	if len(a.Activity) != 1 || a.Activity[0].Actor != "marcus" || a.Activity[0].Action != "criou o card" {
		t.Fatalf("Add deveria logar 'criou o card' por marcus: %+v", a.Activity)
	}
	col := "em_progresso"
	u, _ := s.Update(a.ID, &col, nil, nil, nil, "lauren")
	last := u.Activity[len(u.Activity)-1]
	if last.Actor != "lauren" || last.Action != "moveu para Em progresso" {
		t.Fatalf("move deveria logar 'lauren moveu para Em progresso': %+v", u.Activity)
	}
	// mover pra mesma coluna não gera nova entrada
	n := len(u.Activity)
	u2, _ := s.Update(a.ID, &col, nil, nil, nil, "lauren")
	if len(u2.Activity) != n {
		t.Fatalf("mover pra mesma coluna não deveria logar: %d -> %d", n, len(u2.Activity))
	}
	// actor vazio vira "?"
	done := "concluido"
	u3, _ := s.Update(a.ID, &done, nil, nil, nil, "")
	if u3.Activity[len(u3.Activity)-1].Actor != "?" {
		t.Fatalf("actor vazio deveria virar '?': %+v", u3.Activity)
	}
}

func TestCloseWeekArchivesAndStalls(t *testing.T) {
	s := New()
	done := s.Add(NewTask{Title: "feito", Group: "g", Session: "x"})
	col := "concluido"
	s.Update(done.ID, &col, nil, nil, nil, "")
	oldTodo := s.Add(NewTask{Title: "antigo", Group: "g", Session: "x"})
	recentTodo := s.Add(NewTask{Title: "novo", Group: "g", Session: "x"})
	prog := s.Add(NewTask{Title: "rodando", Group: "g", Session: "x"})
	p := "em_progresso"
	s.Update(prog.ID, &p, nil, nil, nil, "")

	// backdate o oldTodo para antes desta semana (white-box)
	s.mu.Lock()
	ot := s.byID[oldTodo.ID]
	ot.CreatedAt = time.Now().AddDate(0, 0, -14)
	s.byID[oldTodo.ID] = ot
	s.mu.Unlock()

	archived, stalled := s.CloseWeek(time.Now())
	if archived != 1 {
		t.Fatalf("archived=%d, esperava 1", archived)
	}
	if stalled != 1 {
		t.Fatalf("stalled=%d, esperava 1", stalled)
	}
	if _, ok := s.Get(done.ID); ok {
		t.Fatalf("concluido deveria ter saído do board")
	}
	if g, _ := s.Get(oldTodo.ID); !g.Encalhada {
		t.Fatalf("oldTodo deveria ser encalhada")
	}
	if g, _ := s.Get(recentTodo.ID); g.Encalhada {
		t.Fatalf("recentTodo NÃO deveria ser encalhada")
	}
	weeks := s.ArchivedWeeks()
	if len(weeks) != 1 || len(weeks[0].Tasks) != 1 || weeks[0].Tasks[0].ID != done.ID {
		t.Fatalf("arquivo inesperado: %+v", weeks)
	}
	// mover a encalhada para em_progresso limpa a marca
	s.Update(oldTodo.ID, &p, nil, nil, nil, "")
	if g, _ := s.Get(oldTodo.ID); g.Encalhada {
		t.Fatalf("mover deveria limpar encalhada")
	}
}
