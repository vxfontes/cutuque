package server

import (
	"encoding/json"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/registry"
)

// outputResponse é o corpo de GET /sessions/{id}/output.
type outputResponse struct {
	Chunks []string `json:"chunks"`
}

// SessionOutputHandler responde os últimos pedaços de output de uma sessão.
// 404 se a sessão não existir.
func SessionOutputHandler(reg *registry.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if _, ok := reg.Get(id); !ok {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "not_found"})
			return
		}

		chunks := reg.Output(id)
		if chunks == nil {
			chunks = []string{} // serializa como [] e não null
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(outputResponse{Chunks: chunks})
	}
}
