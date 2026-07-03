package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestAppendAndGetOutput(t *testing.T) {
	r := New()
	r.AppendOutput("a", "assistant", "linha 1")
	r.AppendOutput("a", "tool", "linha 2")
	r.AppendOutput("a", "tool_result", "linha 3")

	got := r.Output("a")
	want := []OutputChunk{
		{Kind: "assistant", Text: "linha 1"},
		{Kind: "tool", Text: "linha 2"},
		{Kind: "tool_result", Text: "linha 3"},
	}
	if len(got) != len(want) {
		t.Fatalf("len(Output) = %d, quero %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Output[%d] = %+v, quero %+v", i, got[i], want[i])
		}
	}
}

func TestOutputCapsAt200(t *testing.T) {
	r := New()
	for i := range 250 {
		r.AppendOutput("a", "assistant", fmt.Sprintf("chunk-%d", i))
	}

	got := r.Output("a")
	if len(got) != 200 {
		t.Fatalf("len(Output) = %d, quero 200 (cap)", len(got))
	}
	// Deve manter os 200 mais recentes: chunk-50 .. chunk-249.
	if got[0].Text != "chunk-50" {
		t.Errorf("Output[0].Text = %q, quero \"chunk-50\"", got[0].Text)
	}
	if got[199].Text != "chunk-249" {
		t.Errorf("Output[199].Text = %q, quero \"chunk-249\"", got[199].Text)
	}
}

func TestOutputUnknownSessionIsEmpty(t *testing.T) {
	r := New()
	if got := r.Output("nada"); len(got) != 0 {
		t.Errorf("Output de id inexistente = %v, quero vazio", got)
	}
}

func TestOutputReturnsCopy(t *testing.T) {
	r := New()
	r.AppendOutput("a", "assistant", "orig")
	got := r.Output("a")
	got[0].Text = "mutado"
	if again := r.Output("a"); again[0].Text != "orig" {
		t.Errorf("Output foi mutado externamente: %q", again[0].Text)
	}
}

func TestSubscribeOutputReceives(t *testing.T) {
	r := New()
	sub := r.SubscribeOutput()
	defer r.UnsubscribeOutput(sub)

	r.AppendOutput("a", "assistant", "oi")

	select {
	case ev := <-sub.C:
		if ev.SessionID != "a" || ev.Kind != "assistant" || ev.Text != "oi" {
			t.Errorf("recebido %+v, quero {a, assistant, oi}", ev)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando output")
	}
}

func TestUnsubscribeOutputStopsDelivery(t *testing.T) {
	r := New()
	sub := r.SubscribeOutput()
	r.UnsubscribeOutput(sub)

	r.AppendOutput("a", "assistant", "oi")

	select {
	case _, ok := <-sub.C:
		if ok {
			t.Error("recebeu output após UnsubscribeOutput")
		}
	case <-time.After(200 * time.Millisecond):
	}
}

func TestConcurrentOutputIsRaceFree(t *testing.T) {
	r := New()
	var wg sync.WaitGroup

	stop := make(chan struct{})
	for range 4 {
		sub := r.SubscribeOutput()
		wg.Go(func() {
			for {
				select {
				case <-sub.C:
				case <-stop:
					r.UnsubscribeOutput(sub)
					return
				}
			}
		})
	}

	for i := range 8 {
		wg.Go(func() {
			id := fmt.Sprintf("s%d", i%3)
			r.AppendOutput(id, "assistant", "x")
			_ = r.Output(id)
		})
	}

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	time.Sleep(50 * time.Millisecond)
	close(stop)
	<-done
}
