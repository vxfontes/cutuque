package opencode

import (
	"context"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/agent"
)

func TestTranscriptLocalReconstroiConversa(t *testing.T) {
	requirePython3(t)
	home := t.TempDir()
	sid := fakeStorage(t, home)
	t.Setenv("HOME", home)

	chunks, err := NewLocalTarget("local").Transcript(context.Background(), sid)
	if err != nil {
		t.Fatalf("Transcript: %v", err)
	}

	// Ordem: user (created 1000) → assistant texto (start 2000) → tool (start 3000)
	// + tool_result. O reasoning é ignorado.
	want := []agent.TranscriptChunk{
		{Kind: "user", Text: "liste os arquivos"},
		{Kind: "assistant", Text: "claro, já listo"},
		{Kind: "tool", Text: "bash: ls"},
		{Kind: "tool_result", Text: "arquivo.txt"},
	}
	if len(chunks) != len(want) {
		t.Fatalf("len(chunks) = %d, quero %d: %+v", len(chunks), len(want), chunks)
	}
	for i, w := range want {
		if chunks[i].Kind != w.Kind || chunks[i].Text != w.Text {
			t.Errorf("chunk[%d] = %+v, quero %+v", i, chunks[i], w)
		}
	}
}

func TestTranscriptSessaoInexistenteVazio(t *testing.T) {
	requirePython3(t)
	home := t.TempDir()
	fakeStorage(t, home)
	t.Setenv("HOME", home)

	chunks, err := NewLocalTarget("local").Transcript(context.Background(), "ses_naoexiste0000001")
	if err != nil {
		t.Fatalf("Transcript: %v", err)
	}
	if len(chunks) != 0 {
		t.Fatalf("len(chunks) = %d, quero 0 para sessão inexistente", len(chunks))
	}
}

func TestParseTranscriptVazio(t *testing.T) {
	for _, in := range []string{"", "  ", "[]"} {
		got, err := parseTranscript([]byte(in))
		if err != nil {
			t.Fatalf("parseTranscript(%q) erro: %v", in, err)
		}
		if len(got) != 0 {
			t.Errorf("parseTranscript(%q) = %+v, quero vazio", in, got)
		}
	}
}
