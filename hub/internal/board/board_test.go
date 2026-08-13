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
	s.CloseWeek(time.Now(), "")

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

	archived, stalled := s.CloseWeek(time.Now(), "")
	if archived != 1 {
		t.Fatalf("archived=%d, esperava 1", archived)
	}
	// Os DOIS a_fazer encalham: o corte é o fim da semana fechada, então o card
	// criado nesta semana também atravessou a virada sem começar. O em_progresso
	// não entra — quem saiu da coluna começou.
	if stalled != 2 {
		t.Fatalf("stalled=%d, esperava 2 (os dois a_fazer)", stalled)
	}
	if _, ok := s.Get(done.ID); ok {
		t.Fatalf("concluido deveria ter saído do board")
	}
	if g, _ := s.Get(oldTodo.ID); !g.Encalhada {
		t.Fatalf("oldTodo deveria ser encalhada")
	}
	if g, _ := s.Get(recentTodo.ID); !g.Encalhada {
		t.Fatalf("recentTodo deveria ser encalhada (nasceu na semana que está fechando)")
	}
	if g, _ := s.Get(prog.ID); g.Encalhada {
		t.Fatalf("card em em_progresso não pode encalhar")
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

// concluir adiciona um card já em concluido.
func concluir(s *MemStore, title string) Task {
	t := s.Add(NewTask{Title: title, Group: "g", Session: "x"})
	col := "concluido"
	u, _ := s.Update(t.ID, &col, nil, nil, nil, "")
	return u
}

// O caso da madrugada de segunda: o que foi concluído depois da meia-noite entra
// na semana em que o trabalho aconteceu, não numa semana nova de um card só.
func TestCloseWeekArquivaNaSemanaEscolhida(t *testing.T) {
	s := New()
	concluir(s, "trabalho de domingo à noite")
	segundaDeMadrugada := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC) // 2026-W31

	archived, _ := s.CloseWeek(segundaDeMadrugada, "2026-W30")
	if archived != 1 {
		t.Fatalf("archived=%d, esperava 1", archived)
	}
	weeks := s.ArchivedWeeks()
	if len(weeks) != 1 || weeks[0].Label != "2026-W30" {
		t.Fatalf("esperava tudo na 2026-W30, veio %+v", weeks)
	}
	if weeks[0].Start != "2026-07-20" || weeks[0].End != "2026-07-26" {
		t.Fatalf("intervalo da semana errado: %s a %s", weeks[0].Start, weeks[0].End)
	}
}

// O corte da encalhada é o FIM da semana rotulada, não o começo: fechando a W30,
// o a_fazer criado DENTRO da W30 encalha no fechamento dela mesma — foi o que a
// virada de 13/08/2026 mudou (antes ele ganhava uma semana inteira de carência).
//
// E a fronteira que o corte antigo protegia continua de pé: fechar a W30 às 00:30
// da segunda (já dentro da W31, o caso da madrugada) não pode encalhar o card
// nascido àquela hora — ele é da W31, ainda não atravessou virada nenhuma.
func TestCloseWeekEncalhaQuemAtravessouASemanaFechada(t *testing.T) {
	s := New()
	madrugadaDeSegunda := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC) // 2026-W31

	daSemanaFechada := s.Add(NewTask{Title: "criado na W30", Group: "g", Session: "x"})
	anterior := s.Add(NewTask{Title: "criado na W28", Group: "g", Session: "x"})
	daSemanaNova := s.Add(NewTask{Title: "criado 00:30 de segunda (W31)", Group: "g", Session: "x"})
	backdate := map[string]time.Time{
		daSemanaFechada.ID: time.Date(2026, 7, 22, 10, 0, 0, 0, time.UTC), // quarta da W30
		anterior.ID:        time.Date(2026, 7, 8, 10, 0, 0, 0, time.UTC),  // W28
		daSemanaNova.ID:    madrugadaDeSegunda,
	}
	s.mu.Lock()
	for id, quando := range backdate {
		t := s.byID[id]
		t.CreatedAt = quando
		s.byID[id] = t
	}
	s.mu.Unlock()

	_, stalled := s.CloseWeek(madrugadaDeSegunda, "2026-W30")
	if stalled != 2 {
		t.Fatalf("stalled=%d, esperava 2 (o da W30 e o da W28, não o da W31)", stalled)
	}
	if g, _ := s.Get(daSemanaFechada.ID); !g.Encalhada {
		t.Fatalf("card criado dentro da semana fechada deveria encalhar")
	}
	if g, _ := s.Get(anterior.ID); !g.Encalhada {
		t.Fatalf("card de duas semanas atrás deveria encalhar")
	}
	if g, _ := s.Get(daSemanaNova.ID); g.Encalhada {
		t.Fatalf("card nascido DEPOIS da semana fechada não pode encalhar (fronteira da madrugada)")
	}
}

// O corte tem de andar com o RÓTULO, não com o relógio: fechando a W28 hoje (um
// fechamento atrasado, com rótulo antigo), o que nasceu na W30 fica fora.
func TestCloseWeekCorteAcompanhaORotuloEscolhido(t *testing.T) {
	s := New()
	daW30 := s.Add(NewTask{Title: "criado na W30", Group: "g", Session: "x"})
	daW28 := s.Add(NewTask{Title: "criado na W28", Group: "g", Session: "x"})
	s.mu.Lock()
	a := s.byID[daW30.ID]
	a.CreatedAt = time.Date(2026, 7, 22, 10, 0, 0, 0, time.UTC)
	s.byID[daW30.ID] = a
	b := s.byID[daW28.ID]
	b.CreatedAt = time.Date(2026, 7, 8, 10, 0, 0, 0, time.UTC)
	s.byID[daW28.ID] = b
	s.mu.Unlock()

	_, stalled := s.CloseWeek(time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC), "2026-W28")
	if stalled != 1 {
		t.Fatalf("stalled=%d, esperava só o card da W28", stalled)
	}
	if g, _ := s.Get(daW30.ID); g.Encalhada {
		t.Fatalf("fechando a W28, o card da W30 não pode encalhar")
	}
}

// Rótulo lixo não pode virar uma semana "0000-W00" no arquivo.
func TestCloseWeekRotuloInvalidoCaiNaSemanaDeAgora(t *testing.T) {
	s := New()
	concluir(s, "qualquer coisa")
	now := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC)
	s.CloseWeek(now, "semana passada, por favor")

	weeks := s.ArchivedWeeks()
	if len(weeks) != 1 || weeks[0].Label != "2026-W31" {
		t.Fatalf("esperava cair na semana de now (2026-W31), veio %+v", weeks)
	}
}

func TestCloseOptionsOfereceUltimaSemanaArquivada(t *testing.T) {
	s := New()
	concluir(s, "da W30")
	segundaDeMadrugada := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC)
	s.CloseWeek(segundaDeMadrugada, "2026-W30")
	concluir(s, "pendente 1")
	concluir(s, "pendente 2")

	opt := s.CloseOptions(segundaDeMadrugada)
	if opt.Current.Label != "2026-W31" || opt.Current.Count != 0 {
		t.Fatalf("current inesperado: %+v", opt.Current)
	}
	if opt.Current.Start != "2026-07-27" || opt.Current.End != "2026-08-02" {
		t.Fatalf("intervalo da current errado: %+v", opt.Current)
	}
	if opt.Last == nil || opt.Last.Label != "2026-W30" || opt.Last.Count != 1 {
		t.Fatalf("last inesperado: %+v", opt.Last)
	}
	if opt.Pending != 2 {
		t.Fatalf("pending=%d, esperava 2", opt.Pending)
	}
}

// Arquivo vazio, ou só com a semana atual dentro: não há escolha a oferecer, e o
// cliente cai na confirmação simples.
func TestCloseOptionsSemEscolhaQuandoNaoHaOutraSemana(t *testing.T) {
	s := New()
	now := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC)
	if opt := s.CloseOptions(now); opt.Last != nil {
		t.Fatalf("arquivo vazio não deveria ter last: %+v", opt.Last)
	}
	concluir(s, "fechado na própria semana")
	s.CloseWeek(now, "")
	opt := s.CloseOptions(now)
	if opt.Last != nil {
		t.Fatalf("só a semana atual arquivada não é escolha: %+v", opt.Last)
	}
	if opt.Current.Count != 1 {
		t.Fatalf("current deveria contar o que já foi arquivado nela: %+v", opt.Current)
	}
}

// weekCutoffFor é o corte da encalhada nas duas stores (MemStore e Postgres), e
// é a segunda-feira 00:00 SEGUINTE ao fim da semana rotulada — limite exclusivo.
// A virada do ano é o caso que quebra aritmética ingênua de semana ISO.
func TestWeekCutoffFor(t *testing.T) {
	agora := time.Date(2026, 7, 27, 0, 30, 0, 0, time.UTC) // segunda, W31
	casos := []struct {
		rotulo     string
		querCorte  time.Time
		querUsado  string
		explicacao string
	}{
		{"2026-W30", time.Date(2026, 7, 27, 0, 0, 0, 0, time.UTC), "2026-W30",
			"W30 = 20 a 26/07; o corte é a segunda seguinte, 27/07 00:00"},
		{"2025-W01", time.Date(2025, 1, 6, 0, 0, 0, 0, time.UTC), "2025-W01",
			"W01 de 2025 começa em 30/12/2024 e termina em 05/01/2025"},
		{"2026-W53", time.Date(2027, 1, 4, 0, 0, 0, 0, time.UTC), "2026-W53",
			"2026 não tem W53: a aritmética ISO cai na semana seguinte, sem estourar"},
		{"semana passada, por favor", time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC), "2026-W31",
			"rótulo lixo cai na semana de now (W31), corte na segunda seguinte"},
	}
	for _, c := range casos {
		corte, usado := weekCutoffFor(c.rotulo, agora)
		if !corte.Equal(c.querCorte) || usado != c.querUsado {
			t.Errorf("weekCutoffFor(%q) = (%s, %q), quero (%s, %q) — %s",
				c.rotulo, corte.Format(time.RFC3339), usado,
				c.querCorte.Format(time.RFC3339), c.querUsado, c.explicacao)
		}
	}
}
