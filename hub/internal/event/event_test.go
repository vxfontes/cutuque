package event

import (
	"testing"
	"time"
)

func TestTypeConstants(t *testing.T) {
	cases := map[Type]string{
		SessionStarted:      "session_started",
		OutputChunk:         "output_chunk",
		NeedsInput:          "needs_input",
		PermissionRequested: "permission_requested",
		Finished:            "finished",
		Errored:             "errored",
	}
	for ty, want := range cases {
		if string(ty) != want {
			t.Errorf("Type = %q, quero %q", string(ty), want)
		}
	}
}

func TestEventFields(t *testing.T) {
	at := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	e := Event{SessionID: "abc", Type: OutputChunk, Data: "oi", At: at}
	if e.SessionID != "abc" || e.Type != OutputChunk || e.Data != "oi" || !e.At.Equal(at) {
		t.Errorf("Event = %+v, campos inesperados", e)
	}
}
