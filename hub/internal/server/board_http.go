package server

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

// boardLoc é o fuso do fechamento semanal (domingo 23:59).
func boardLoc() *time.Location {
	if loc, err := time.LoadLocation("America/Sao_Paulo"); err == nil {
		return loc
	}
	return time.UTC
}

// NOTA: reusa o helper JÁ EXISTENTE `writeJSONResp(w, status, v)` (settings.go).
// NÃO declarar `writeJSON` aqui — o pacote server já tem um `writeJSON` com
// outra assinatura (ws.go), o que causaria erro de redeclaração.

// BoardListHandler responde a lista de tarefas.
func BoardListHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tasks := st.List()
		if tasks == nil {
			tasks = []board.Task{}
		}
		writeJSONResp(w, http.StatusOK, map[string]any{"tasks": tasks})
	}
}

// BoardCreateHandler cria uma tarefa (coluna inicial a_fazer).
func BoardCreateHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Title       string `json:"title"`
			Group       string `json:"group"`
			Session     string `json:"session"`
			Type        string `json:"type"`
			Role        string `json:"role"`
			Description string `json:"description"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil || in.Title == "" {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		writeJSONResp(w, http.StatusCreated, st.Add(board.NewTask{
			Title: in.Title, Group: in.Group, Session: in.Session,
			Type: in.Type, Role: in.Role, Description: in.Description,
		}))
	}
}

// BoardPatchHandler move/edita uma tarefa (coluna, título, descrição, role).
func BoardPatchHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var in struct {
			Column      *string `json:"column"`
			Title       *string `json:"title"`
			Description *string `json:"description"`
			Role        *string `json:"role"`
			Encalhada   *bool   `json:"encalhada"`
			Actor       string  `json:"actor"` // quem fez a ação (log de atividade)
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		if in.Column != nil && !board.ValidColumn(*in.Column) {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "invalid_column"})
			return
		}
		var t board.Task
		ok := false
		if in.Column != nil || in.Title != nil || in.Description != nil || in.Role != nil {
			t, ok = st.Update(id, in.Column, in.Title, in.Description, in.Role, in.Actor)
		}
		// Encalhada é aplicada por último (o Update limpa a marca ao mover; um
		// pedido explícito de encalhada=true tem que sobrepor isso).
		if in.Encalhada != nil {
			t, ok = st.SetEncalhada(id, *in.Encalhada, in.Actor)
		}
		if !ok {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		writeJSONResp(w, http.StatusOK, t)
	}
}

// BoardCommentHandler adiciona uma observação a um card.
func BoardCommentHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		var in struct {
			Author string `json:"author"`
			Text   string `json:"text"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in) != nil || in.Text == "" {
			writeJSONResp(w, http.StatusBadRequest, map[string]string{"error": "bad_request"})
			return
		}
		author := in.Author
		if author == "" {
			author = "?"
		}
		t, ok := st.AddComment(id, author, in.Text)
		if !ok {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		writeJSONResp(w, http.StatusCreated, t)
	}
}

// BoardArchiveHandler responde o arquivo (concluídos por semana, mais recente 1º).
func BoardArchiveHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		weeks := st.ArchivedWeeks()
		if weeks == nil {
			weeks = []board.ArchivedWeek{}
		}
		writeJSONResp(w, http.StatusOK, map[string]any{"weeks": weeks})
	}
}

// BoardCloseHandler fecha a semana manualmente (arquiva concluídos + marca encalhadas).
func BoardCloseHandler(st board.Store) http.HandlerFunc {
	loc := boardLoc()
	return func(w http.ResponseWriter, r *http.Request) {
		archived, stalled := st.CloseWeek(time.Now().In(loc))
		writeJSONResp(w, http.StatusOK, map[string]int{"archived": archived, "stalled": stalled})
	}
}

// BoardDeleteHandler remove uma tarefa.
func BoardDeleteHandler(st board.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !st.Remove(r.PathValue("id")) {
			writeJSONResp(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
