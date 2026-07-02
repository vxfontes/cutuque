package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestAppendAndGetOutput(t *testing.T) {
	r := New()
	r.AppendOutput("a", "linha 1")
	r.AppendOutput("a", "linha 2")
	r.AppendOutput("a", "linha 3")

	got := r.Output("a")
	want := []string{"linha 1", "linha 2", "linha 3"}
	if len(got) != len(want) {
		t.Fatalf("len(Output) = %d, quero %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Output[%d] = %q, quero %q", i, got[i], want[i])
		}
	}
}

func TestOutputCapsAt200(t *testing.T) {
	r := New()
	for i := range 250 {
		r.AppendOutput("a", fmt.Sprintf("chunk-%d", i))
	}

	got := r.Output("a")
	if len(got) != 200 {
		t.Fatalf("len(Output) = %d, quero 200 (cap)", len(got))
	}
	// Deve manter os 200 mais recentes: chunk-50 .. chunk-249.
	if got[0] != "chunk-50" {
		t.Errorf("Output[0] = %q, quero \"chunk-50\"", got[0])
	}
	if got[199] != "chunk-249" {
		t.Errorf("Output[199] = %q, quero \"chunk-249\"", got[199])
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
	r.AppendOutput("a", "orig")
	got := r.Output("a")
	got[0] = "mutado"
	if again := r.Output("a"); again[0] != "orig" {
		t.Errorf("Output foi mutado externamente: %q", again[0])
	}
}

func TestSubscribeOutputReceives(t *testing.T) {
	r := New()
	sub := r.SubscribeOutput()
	defer r.UnsubscribeOutput(sub)

	r.AppendOutput("a", "oi")

	select {
	case ev := <-sub.C:
		if ev.SessionID != "a" || ev.Data != "oi" {
			t.Errorf("recebido %+v, quero {a, oi}", ev)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando output")
	}
}

func TestUnsubscribeOutputStopsDelivery(t *testing.T) {
	r := New()
	sub := r.SubscribeOutput()
	r.UnsubscribeOutput(sub)

	r.AppendOutput("a", "oi")

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
			r.AppendOutput(id, "x")
			_ = r.Output(id)
		})
	}

	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	time.Sleep(50 * time.Millisecond)
	close(stop)
	<-done
}
