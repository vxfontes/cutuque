package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

// readUntilType lê mensagens do WS até achar uma com o "type" pedido (ou
// esgotar maxMsgs), decodificando o payload bruto em out. Usado porque o
// snapshot de sessão e o board_snapshot são enviados em sequência mas sem
// ordem garantida entre si — o teste não pode assumir qual chega primeiro.
func readUntilType(t *testing.T, ctx context.Context, c *websocket.Conn, wantType string, out any, maxMsgs int) {
	t.Helper()
	for i := 0; i < maxMsgs; i++ {
		var raw json.RawMessage
		if err := wsjson.Read(ctx, c, &raw); err != nil {
			t.Fatalf("lendo mensagem %d (esperando %q): %v", i, wantType, err)
		}
		var typ struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &typ); err != nil {
			t.Fatalf("decodificando type da mensagem %d: %v", i, err)
		}
		if typ.Type != wantType {
			continue
		}
		if err := json.Unmarshal(raw, out); err != nil {
			t.Fatalf("decodificando payload %q: %v", wantType, err)
		}
		return
	}
	t.Fatalf("não recebeu mensagem tipo %q em %d tentativas", wantType, maxMsgs)
}

// TestBoardWSSnapshotThenUpdate é o round-trip real do board no WS (a
// contraparte de TestWSSendsSnapshotThenUpdates em ws_test.go, mas para o
// Cutuque Board): dial de verdade, subscribe-antes-do-snapshot e o guard de
// canal nil em WSHandler (aqui exercido com bd != nil) — nada disso é
// coberto pelos testes de forma de struct acima.
func TestBoardWSSnapshotThenUpdate(t *testing.T) {
	cfg, reg := testDeps()
	store := board.New()
	pre := store.Add("primeira tarefa", "g1", "s1")

	srv := httptest.NewServer(Router(cfg, reg, nil, WithBoard(store)))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, wsURL(srv.URL), nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	// A primeira leva de mensagens inclui o snapshot de sessão (vazio) e o
	// board_snapshot; pula o que não for board_snapshot.
	var boardSnap boardSnapshotMessage
	readUntilType(t, ctx, c, "board_snapshot", &boardSnap, 5)
	if len(boardSnap.Tasks) != 1 || boardSnap.Tasks[0].ID != pre.ID {
		t.Fatalf("board_snapshot.tasks = %+v, quero 1 task %q", boardSnap.Tasks, pre.ID)
	}

	// Task criada depois de conectado deve ser broadcastada como board_updated.
	nova := store.Add("nova", "g", "s")

	var upd boardUpdatedMessage
	readUntilType(t, ctx, c, "board_updated", &upd, 5)
	if upd.Task.ID != nova.ID || upd.Task.Title != "nova" {
		t.Fatalf("board_updated.task = %+v, quero id=%q title=\"nova\"", upd.Task, nova.ID)
	}
}

func TestBoardWSMessages(t *testing.T) {
	snap := boardSnapshotMessage{Type: "board_snapshot", Tasks: []board.Task{{ID: "1", Column: "a_fazer"}}}
	b, _ := json.Marshal(snap)
	if string(b) == "" || snap.Type != "board_snapshot" {
		t.Fatalf("snapshot msg inválida: %s", b)
	}
	upd := boardUpdatedMessage{Type: "board_updated", Task: board.Task{ID: "1"}}
	if upd.Type != "board_updated" {
		t.Fatalf("updated msg inválida")
	}
	rem := boardRemovedMessage{Type: "board_removed", ID: "1"}
	if rem.Type != "board_removed" || rem.ID != "1" {
		t.Fatalf("removed msg inválida")
	}
}
