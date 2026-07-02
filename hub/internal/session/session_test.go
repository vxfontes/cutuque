package session

import (
	"encoding/json"
	"testing"
	"time"
)

func TestStateConstants(t *testing.T) {
	cases := map[State]string{
		StateRunning:  "running",
		StateNeedsYou: "needs_you",
		StateDone:     "done",
		StateError:    "error",
		StateIdle:     "idle",
	}
	for st, want := range cases {
		if string(st) != want {
			t.Errorf("State = %q, quero %q", string(st), want)
		}
	}
}

func TestSessionMarshalsSnakeCase(t *testing.T) {
	created := time.Date(2026, 7, 2, 10, 30, 0, 0, time.UTC)
	updated := time.Date(2026, 7, 2, 10, 35, 0, 0, time.UTC)
	s := Session{
		ID:        "abc",
		Machine:   "macbook",
		Agent:     "claude-code",
		Title:     "refatorar auth",
		State:     StateRunning,
		CreatedAt: created,
		UpdatedAt: updated,
	}

	raw, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	want := map[string]any{
		"id":         "abc",
		"machine":    "macbook",
		"agent":      "claude-code",
		"title":      "refatorar auth",
		"state":      "running",
		"created_at": "2026-07-02T10:30:00Z",
		"updated_at": "2026-07-02T10:35:00Z",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("campo %q = %v, quero %v", k, got[k], v)
		}
	}
	if len(got) != len(want) {
		t.Errorf("campos = %d (%v), quero %d", len(got), got, len(want))
	}
}

func TestSessionRoundTrip(t *testing.T) {
	created := time.Date(2026, 7, 2, 10, 30, 0, 0, time.UTC)
	s := Session{
		ID:        "xyz",
		Machine:   "desktop-win",
		Agent:     "codex",
		Title:     "rodar testes",
		State:     StateNeedsYou,
		CreatedAt: created,
		UpdatedAt: created,
	}

	raw, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var back Session
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if back != s {
		t.Errorf("round-trip = %+v, quero %+v", back, s)
	}
}
