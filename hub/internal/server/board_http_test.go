package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

func TestBoardCreateAndList(t *testing.T) {
	st := board.New()

	// POST cria
	body := bytes.NewBufferString(`{"title":"rodar testes","group":"interconexao","session":"cutuque"}`)
	rec := httptest.NewRecorder()
	BoardCreateHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/board/tasks", body))
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST status: %d", rec.Code)
	}
	var created board.Task
	_ = json.Unmarshal(rec.Body.Bytes(), &created)
	if created.ID == "" || created.Column != "a_fazer" {
		t.Fatalf("POST body: %+v", created)
	}

	// GET lista
	rec = httptest.NewRecorder()
	BoardListHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET status: %d", rec.Code)
	}
}

func TestBoardPatchMoveAndDelete(t *testing.T) {
	st := board.New()
	task := st.Add(board.NewTask{Title: "x", Group: "g", Session: "s"})

	// PATCH move
	req := httptest.NewRequest(http.MethodPatch, "/board/tasks/"+task.ID, bytes.NewBufferString(`{"column":"feito"}`))
	req.SetPathValue("id", task.ID)
	rec := httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH status: %d", rec.Code)
	}
	var moved board.Task
	_ = json.Unmarshal(rec.Body.Bytes(), &moved)
	if moved.Column != "feito" {
		t.Fatalf("PATCH não moveu: %+v", moved)
	}

	// PATCH coluna inválida -> 400
	req = httptest.NewRequest(http.MethodPatch, "/board/tasks/"+task.ID, bytes.NewBufferString(`{"column":"zzz"}`))
	req.SetPathValue("id", task.ID)
	rec = httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("PATCH inválido status: %d", rec.Code)
	}

	// DELETE
	req = httptest.NewRequest(http.MethodDelete, "/board/tasks/"+task.ID, nil)
	req.SetPathValue("id", task.ID)
	rec = httptest.NewRecorder()
	BoardDeleteHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE status: %d", rec.Code)
	}

	// PATCH de id inexistente -> 404
	req = httptest.NewRequest(http.MethodPatch, "/board/tasks/none", bytes.NewBufferString(`{"column":"feito"}`))
	req.SetPathValue("id", "none")
	rec = httptest.NewRecorder()
	BoardPatchHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("PATCH 404 status: %d", rec.Code)
	}
}

func TestBoardCommentHandler(t *testing.T) {
	st := board.New()
	task := st.Add(board.NewTask{Title: "x", Group: "g", Session: "s"})

	// POST comentário
	req := httptest.NewRequest(http.MethodPost, "/board/tasks/"+task.ID+"/comments", bytes.NewBufferString(`{"author":"marcus","text":"observação"}`))
	req.SetPathValue("id", task.ID)
	rec := httptest.NewRecorder()
	BoardCommentHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST comment status: %d", rec.Code)
	}
	var got board.Task
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if len(got.Comments) != 1 || got.Comments[0].Text != "observação" {
		t.Fatalf("comentário não anexado: %+v", got.Comments)
	}

	// texto vazio -> 400
	req = httptest.NewRequest(http.MethodPost, "/board/tasks/"+task.ID+"/comments", bytes.NewBufferString(`{"author":"x","text":""}`))
	req.SetPathValue("id", task.ID)
	rec = httptest.NewRecorder()
	BoardCommentHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("comment vazio status: %d", rec.Code)
	}

	// id inexistente -> 404
	req = httptest.NewRequest(http.MethodPost, "/board/tasks/none/comments", bytes.NewBufferString(`{"text":"y"}`))
	req.SetPathValue("id", "none")
	rec = httptest.NewRecorder()
	BoardCommentHandler(st).ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("comment 404 status: %d", rec.Code)
	}
}

// arquivarEm fecha a semana num rótulo, via handler, e devolve o status.
func arquivarEm(t *testing.T, st board.Store, week string) int {
	t.Helper()
	url := "/board/close"
	if week != "" {
		url += "?week=" + week
	}
	rec := httptest.NewRecorder()
	BoardCloseHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, url, nil))
	return rec.Code
}

// concluido adiciona um card já na coluna concluido.
func concluido(st board.Store, title string) board.Task {
	task := st.Add(board.NewTask{Title: title, Group: "g", Session: "s"})
	col := "concluido"
	u, _ := st.Update(task.ID, &col, nil, nil, nil, "")
	return u
}

func TestBoardCloseOptionsHandler(t *testing.T) {
	st := board.New()
	rec := httptest.NewRecorder()
	BoardCloseOptionsHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board/close-options", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status: %d", rec.Code)
	}
	var opts board.CloseOptions
	if err := json.Unmarshal(rec.Body.Bytes(), &opts); err != nil {
		t.Fatalf("json: %v (%s)", err, rec.Body.String())
	}
	if opts.Current.Label == "" || opts.Current.Start == "" || opts.Current.End == "" {
		t.Fatalf("current incompleta: %+v", opts.Current)
	}
	if opts.Last != nil {
		t.Fatalf("arquivo vazio não tem última semana: %+v", opts.Last)
	}

	// Com uma semana anterior no arquivo, ela vira a opção "juntar".
	concluido(st, "de antes")
	if code := arquivarEm(t, st, ""); code != http.StatusOK {
		t.Fatalf("fechar: %d", code)
	}
	// A semana arquivada é a atual, então continua sem escolha a fazer.
	rec = httptest.NewRecorder()
	BoardCloseOptionsHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board/close-options", nil))
	_ = json.Unmarshal(rec.Body.Bytes(), &opts)
	if opts.Last != nil {
		t.Fatalf("só a semana atual arquivada não é escolha: %+v", opts.Last)
	}
	if opts.Current.Count != 1 {
		t.Fatalf("current deveria contar 1 arquivado: %+v", opts.Current)
	}
}

// Um typo no rótulo não pode abrir uma semana fantasma no arquivo.
func TestBoardCloseRecusaSemanaDesconhecida(t *testing.T) {
	st := board.New()
	concluido(st, "pendente")
	if code := arquivarEm(t, st, "1999-W01"); code != http.StatusBadRequest {
		t.Fatalf("status=%d, esperava 400", code)
	}
	if len(st.ArchivedWeeks()) != 0 {
		t.Fatalf("nada deveria ter sido arquivado: %+v", st.ArchivedWeeks())
	}
	// E o card continua no board, disponível pro fechamento certo.
	if code := arquivarEm(t, st, ""); code != http.StatusOK {
		t.Fatalf("fechar sem week: %d", code)
	}
	if len(st.ArchivedWeeks()) != 1 {
		t.Fatalf("deveria ter arquivado agora: %+v", st.ArchivedWeeks())
	}
}

// O caminho que a Vanessa vai usar: fechar hoje arquivando na semana anterior.
func TestBoardCloseAceitaUltimaSemanaArquivada(t *testing.T) {
	// A semana da vez é sempre a de hoje; a "passada" é uma que já esteja no
	// arquivo. Deriva do relógio para o teste não expirar quando 2026-W30 chegar.
	st := board.New()
	rec := httptest.NewRecorder()
	BoardCloseOptionsHandler(st).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board/close-options", nil))
	var opts board.CloseOptions
	_ = json.Unmarshal(rec.Body.Bytes(), &opts)
	inicioDaAtual := mustTime(t, opts.Current.Start)
	umaSemanaAntes := inicioDaAtual.AddDate(0, 0, -7)

	st2 := board.New()
	concluido(st2, "trabalho de madrugada")
	st2.CloseWeek(umaSemanaAntes, "") // arquivo com a semana anterior dentro
	anterior := st2.ArchivedWeeks()[0].Label
	concluido(st2, "mais um de madrugada")

	rec = httptest.NewRecorder()
	BoardCloseOptionsHandler(st2).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/board/close-options", nil))
	_ = json.Unmarshal(rec.Body.Bytes(), &opts)
	if opts.Last == nil || opts.Last.Label != anterior {
		t.Fatalf("esperava a W30 como opção: %+v", opts.Last)
	}
	if opts.Pending != 1 {
		t.Fatalf("pending=%d, esperava 1", opts.Pending)
	}
	if code := arquivarEm(t, st2, anterior); code != http.StatusOK {
		t.Fatalf("fechar na W30: %d", code)
	}
	weeks := st2.ArchivedWeeks()
	if len(weeks) != 1 || weeks[0].Label != anterior || len(weeks[0].Tasks) != 2 {
		t.Fatalf("os dois cards deveriam estar na W30: %+v", weeks)
	}
}

func mustTime(t *testing.T, day string) time.Time {
	t.Helper()
	d, err := time.Parse("2006-01-02", day)
	if err != nil {
		t.Fatalf("data: %v", err)
	}
	return d
}
