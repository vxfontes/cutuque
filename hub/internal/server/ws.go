package server

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

// Timeouts do WebSocket. Sem eles, uma conexão travada (celular dormindo,
// troca de rede) prenderia a goroutine, a Subscription e o buffer do canal
// indefinidamente (ver review/security.md, item bloqueante #2). O ping
// periódico detecta a queda; o timeout por escrita evita bloqueio longo.
var (
	wsPingInterval = 30 * time.Second
	wsWriteTimeout = 10 * time.Second
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

// outputMessage é enviada a cada novo pedaço de output de uma sessão.
type outputMessage struct {
	Type      string `json:"type"` // sempre "output_chunk"
	SessionID string `json:"session_id"`
	Data      string `json:"data"`
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
		outSub := reg.SubscribeOutput()
		defer reg.UnsubscribeOutput(outSub)

		// CloseRead descarta o que o cliente enviar e cancela o ctx quando a
		// conexão cai, permitindo encerrar o loop de escrita.
		ctx := c.CloseRead(r.Context())

		snap := snapshotMessage{Type: "snapshot", Sessions: reg.List()}
		if err := writeJSON(ctx, c, snap); err != nil {
			return
		}

		ping := time.NewTicker(wsPingInterval)
		defer ping.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ping.C:
				// Ping com timeout: se a conexão morreu, encerra e libera a
				// subscription/goroutine pelos defers acima.
				pctx, cancel := context.WithTimeout(ctx, wsWriteTimeout)
				err := c.Ping(pctx)
				cancel()
				if err != nil {
					return
				}
			case s, ok := <-sub.C:
				if !ok {
					return // registry encerrou a assinatura
				}
				msg := updatedMessage{Type: "session_updated", Session: s}
				if err := writeJSON(ctx, c, msg); err != nil {
					return
				}
			case o, ok := <-outSub.C:
				if !ok {
					return
				}
				msg := outputMessage{Type: "output_chunk", SessionID: o.SessionID, Data: o.Data}
				if err := writeJSON(ctx, c, msg); err != nil {
					return
				}
			}
		}
	}
}

// writeJSON serializa v para o cliente com um timeout de escrita, para nunca
// bloquear indefinidamente numa conexão travada.
func writeJSON(ctx context.Context, c *websocket.Conn, v any) error {
	wctx, cancel := context.WithTimeout(ctx, wsWriteTimeout)
	defer cancel()
	return wsjson.Write(wctx, c, v)
}
