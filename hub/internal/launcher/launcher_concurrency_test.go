package launcher

import (
	"bufio"
	"context"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// greedyPermissionScript é como permissionScript, mas segue lendo o stdin até o
// EOF e capturando TUDO que chegar — se um segundo control_response for escrito
// (o bug do review F3, achado #2), ele aparece no canal e o teste o denuncia.
func greedyPermissionScript(stdout io.Writer, stdin *bufio.Reader, captured chan<- string) {
	_, _ = stdin.ReadString('\n') // consome o prompt inicial
	_, _ = io.WriteString(stdout, initLine+"\n")
	_, _ = io.WriteString(stdout, controlLn+"\n")
	resp, _ := stdin.ReadString('\n')
	captured <- trimNL(resp)
	_, _ = io.WriteString(stdout, resultLine+"\n")
	for {
		extra, err := stdin.ReadString('\n')
		if err != nil {
			return
		}
		captured <- trimNL(extra)
	}
}

// TestConcurrentApproveDenyWritesSingleResponse cobre o achado #2 do review F3:
// Approve e Deny disparados em corrida para a MESMA permissão devem produzir
// exatamente UM control_response no stdin do processo — o perdedor recebe
// ErrStaleState sem escrever nada. Roda sob -race.
func TestConcurrentApproveDenyWritesSingleResponse(t *testing.T) {
	tgt := &scriptTarget{name: "macbook", run: greedyPermissionScript, captured: make(chan string, 4)}
	l, reg := newTestLauncher(tgt)

	if _, err := l.Launch(context.Background(), "macbook", "claude-code", "faça algo", "", "", ""); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	waitFor(t, func() bool {
		s, ok := reg.Get(sid)
		return ok && s.State == session.StateNeedsYou
	})

	start := make(chan struct{})
	errs := make([]error, 2)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); <-start; errs[0] = l.Approve(sid) }()
	go func() { defer wg.Done(); <-start; errs[1] = l.Deny(sid) }()
	close(start)
	wg.Wait()

	// Exatamente uma ação vence; a outra é rejeitada como obsoleta.
	winners := 0
	for i, err := range errs {
		switch err {
		case nil:
			winners++
		case ErrStaleState:
			// perdedor esperado
		default:
			t.Errorf("errs[%d] = %v, quero nil ou ErrStaleState", i, err)
		}
	}
	if winners != 1 {
		t.Fatalf("vencedores = %d, quero exatamente 1 (errs: %v)", winners, errs)
	}

	// Exatamente UM control_response chegou ao processo (allow OU deny).
	first := <-tgt.captured
	if first != wantAllow && first != wantDeny {
		t.Errorf("control_response inesperado: %s", first)
	}
	select {
	case extra := <-tgt.captured:
		t.Fatalf("segundo control_response escrito ao processo (double-response): %s", extra)
	case <-time.After(150 * time.Millisecond):
		// silêncio = correto
	}
}
