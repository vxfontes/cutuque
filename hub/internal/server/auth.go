package server

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
)

// requireAuth exige um token válido antes de chamar next. Aceita o token de
// duas formas:
//   - header "Authorization: Bearer <token>" (REST);
//   - query param "?token=<token>" (para o WebSocket, onde não dá para setar
//     headers no navegador).
//
// Sem token válido responde 401 com JSON {"error":"unauthorized"}.
func requireAuth(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !validToken(token, tokenFromRequest(r)) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// validToken compara o token configurado com o recebido em tempo constante.
// Um token configurado vazio NUNCA é válido: isso evita o bypass total em prod
// quando CUTUQUE_TOKEN não é definido (o middleware não pode tratar "" como um
// valor de comparação legítimo). Ver review/security.md#SEC-001 e SEC-002.
func validToken(configured, provided string) bool {
	if configured == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(configured), []byte(provided)) == 1
}

// tokenFromRequest extrai o token do header Authorization (Bearer) ou, na falta
// dele, do query param token.
func tokenFromRequest(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if after, ok := strings.CutPrefix(h, "Bearer "); ok {
			return after
		}
		return "" // header presente mas malformado: não cai no query param
	}
	return r.URL.Query().Get("token")
}
