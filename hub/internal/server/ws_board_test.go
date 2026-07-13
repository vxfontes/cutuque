package server

import (
	"encoding/json"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

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
