package server

import (
	"net/http"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// snapshotMessage é enviada ao conectar: o estado atual de todas as sessões.
type snapshotMessage struct {
	Type     string            `json:"type"` // sempre "snapshot"
	Sessions []session.Session `json:"sessions"`
}

// updatedMessage é enviada a cada mudança no registry (Add/UpdateState).
type updatedMessage struct {
	Type    string          `json:"type"` // sempre "session_updated"
	Session session.Session `json:"session"`
}

// WSHandler faz o upgrade para WebSocket e transmite o estado das sessões:
// um snapshot inicial e, em seguida, uma mensagem por mudança no registry.
func WSHandler(reg *registry.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return // Accept já respondeu o erro de handshake
		}
		defer c.CloseNow()

		// Assina ANTES do snapshot: eventos entre o snapshot e a assinatura
		// ficam no canal (entrega ao menos uma vez; duplicata é idempotente no
		// cliente). O contrário poderia perder um evento.
		sub := reg.Subscribe()
		defer reg.Unsubscribe(sub)

		// CloseRead descarta o que o cliente enviar e cancela o ctx quando a
		// conexão cai, permitindo encerrar o loop de escrita.
		ctx := c.CloseRead(r.Context())

		snap := snapshotMessage{Type: "snapshot", Sessions: reg.List()}
		if err := wsjson.Write(ctx, c, snap); err != nil {
			return
		}

		for {
			select {
			case <-ctx.Done():
				return
			case s, ok := <-sub.C:
				if !ok {
					return // registry encerrou a assinatura
				}
				msg := updatedMessage{Type: "session_updated", Session: s}
				if err := wsjson.Write(ctx, c, msg); err != nil {
					return
				}
			}
		}
	}
}
