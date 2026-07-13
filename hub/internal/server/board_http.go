package server

import (
	"encoding/json"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

// NOTA: reusa o helper JÁ EXISTENTE `writeJSONResp(w, status, v)` (settings.go).
// NÃO declarar `writeJSON` aqui — o pacote server já tem um `writeJSON` com
// outra assinatura (ws.go), o que causaria erro de redeclaração.

// BoardListHandler responde a lista de tarefas.
func BoardListHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tasks := st.List()
		if tasks == nil {
			tasks = []board.Task{}
		}
		writeJSONResp(w, http.StatusOK, map[string]any{"tasks": tasks})
	}
}

// BoardCreateHandler cria uma tarefa (coluna inicial a_fazer).
func BoardCreateHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Title, Group, Session string }
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil || in.Title == "" {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		writeJSONResp(w, http.StatusCreated, st.Add(in.Title, in.Group, in.Session))
	}
}

// BoardPatchHandler move/edita uma tarefa.
func BoardPatchHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var in struct {
			Column *string `json:"column"`
			Title  *string `json:"title"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		if in.Column != nil && !board.ValidColumn(*in.Column) {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "invalid_column"})
			return
		}
		t, ok := st.Update(id, in.Column, in.Title)
		if !ok {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		writeJSONResp(w, http.StatusOK, t)
	}
}

// BoardDeleteHandler remove uma tarefa.
func BoardDeleteHandler(st *board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !st.Remove(r.PathValue("id")) {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
