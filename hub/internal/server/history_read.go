package server

import (
	"context"
	"net/http"
	"strconv"

	"github.com/vxfontes/cutuque/hub/internal/history"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// HistoryReader é a leitura do histórico persistido (Postgres). O
// history.PostgresStore o satisfaz. Só é ligado quando CUTUQUE_DATABASE_URL
// está configurado; sem ele, as rotas /history nem são registradas.
type HistoryReader interface {
	RecentSessions(ctx context.Context, limit int) ([]session.Session, error)
	SessionEvents(ctx context.Context, sessionID string, limit int) ([]history.StoredEvent, error)
}

// pastSessionsResponse é o corpo de GET /history.
type pastSessionsResponse struct {
	Sessions []session.Session `json:"sessions"`
}

// sessionTimelineResponse é o corpo de GET /history/{id}/events.
type sessionTimelineResponse struct {
	Events []history.StoredEvent `json:"events"`
}

// queryLimit lê ?limit=N (1..max), caindo no default se ausente/inválido.
func queryLimit(r *http.Request, def, max int) int {
	n, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || n <= 0 {
		return def
	}
	if n > max {
		return max
	}
	return n
}

// PastSessionsHandler lista as sessões passadas (mais recentes primeiro) do
// histórico. 200 {"sessions":[...]} | 500 history_error.
func PastSessionsHandler(h HistoryReader) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ss, err := h.RecentSessions(r.Context(), queryLimit(r, 100, 500))
		if err != nil {
			writeJSONResp(w, http.StatusInternalServerError, map[string]string{"error": "history_error"})
			return
		}
		if ss == nil {
			ss = []session.Session{}
		}
		writeJSONResp(w, http.StatusOK, pastSessionsResponse{Sessions: ss})
	}
}

// SessionTimelineHandler devolve a linha do tempo (eventos) de UMA sessão do
// histórico. 200 {"events":[...]} | 500 history_error.
func SessionTimelineHandler(h HistoryReader) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		evs, err := h.SessionEvents(r.Context(), id, queryLimit(r, 1000, 5000))
		if err != nil {
			writeJSONResp(w, http.StatusInternalServerError, map[string]string{"error": "history_error"})
			return
		}
		if evs == nil {
			evs = []history.StoredEvent{}
		}
		writeJSONResp(w, http.StatusOK, sessionTimelineResponse{Events: evs})
	}
}
