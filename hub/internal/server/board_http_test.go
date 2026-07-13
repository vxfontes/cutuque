package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

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
