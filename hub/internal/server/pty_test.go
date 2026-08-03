package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
)

// abrePTY sobe o router com um fakeLauncher que roda `prog args...` no lugar do
// `ssh` e devolve o WebSocket já conectado. O PTY é de verdade: não dá para
// fingir um terminal com mock, e é justamente o comportamento de terminal
// (eco, tamanho, sinal de saída) que está sendo testado.
func abrePTY(t *testing.T, f *fakeLauncher) (*websocket.Conn, context.Context) {
	t.Helper()
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, f))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/machines/vps/pty?token=secret&cols=100&rows=40"
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	return c, ctx
}

// leAte junta a saída binária até bater o que se procura (ou o prazo estourar).
// Terminal não entrega em pedaços previsíveis — esperar "a próxima mensagem"
// seria um teste instável.
func leAte(t *testing.T, ctx context.Context, c *websocket.Conn, procurado string) string {
	t.Helper()
	var visto strings.Builder
	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("procurando %q, li só %q: %v", procurado, visto.String(), err)
		}
		if typ != websocket.MessageBinary {
			continue // metadado (exit/error) não é saída do terminal
		}
		visto.Write(data)
		if strings.Contains(visto.String(), procurado) {
			return visto.String()
		}
	}
}

// O caminho inteiro: o que o app manda em frame binário chega no terminal, e o
// que o terminal produz volta.
func TestPTYLevaEDevolveBytes(t *testing.T) {
	c, ctx := abrePTY(t, &fakeLauncher{shellProg: "cat"})

	if err := c.Write(ctx, websocket.MessageBinary, []byte("cutuquei\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	leAte(t, ctx, c, "cutuquei")
}

// O tamanho da tela precisa chegar ao processo do outro lado como tamanho de
// terminal de verdade — é isso que faz o vim e o htop desenharem certo. O
// `stty size` responde o que o kernel sabe do tty, então é a prova.
func TestPTYRedimensionaOTerminalDeVerdade(t *testing.T) {
	// Espera uma linha antes de medir: assim o resize chega antes da medição
	// sem o teste depender de sleep.
	c, ctx := abrePTY(t, &fakeLauncher{shellProg: "sh", shellArgs: []string{"-c", "read x; stty size"}})

	ctl, _ := json.Marshal(ptyControl{Type: "resize", Cols: 120, Rows: 45})
	if err := c.Write(ctx, websocket.MessageText, ctl); err != nil {
		t.Fatalf("resize: %v", err)
	}
	if err := c.Write(ctx, websocket.MessageBinary, []byte("\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	leAte(t, ctx, c, "45 120")
}

// Sem resize, vale o tamanho que veio na query do handshake — o app mede a tela
// antes de conectar e não deveria precisar de um segundo round-trip.
func TestPTYUsaOTamanhoDoHandshake(t *testing.T) {
	c, ctx := abrePTY(t, &fakeLauncher{shellProg: "sh", shellArgs: []string{"-c", "stty size"}})
	leAte(t, ctx, c, "40 100")
}

// "Você digitou exit" e "a rede caiu" não podem chegar iguais no app: o código
// de saída é a diferença entre reconectar e mostrar que acabou.
func TestPTYAvisaOCodigoDeSaida(t *testing.T) {
	c, ctx := abrePTY(t, &fakeLauncher{shellProg: "sh", shellArgs: []string{"-c", "exit 7"}})

	for {
		typ, data, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("esperava o aviso de saída: %v", err)
		}
		if typ != websocket.MessageText {
			continue
		}
		var ev ptyEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			t.Fatalf("evento não é json: %v — %s", err, data)
		}
		if ev.Type != "exit" || ev.Code != 7 {
			t.Fatalf("evento = %+v, quero exit com code 7", ev)
		}
		return
	}
}

// Máquina que não existe tem que falhar como HTTP, ANTES do upgrade: um
// WebSocket que abre e fecha na cara não diz nada ao app.
func TestPTYMaquinaDesconhecidaE404(t *testing.T) {
	rec := pedePTY(t, &fakeLauncher{shellErr: launcher.ErrUnknownMachine})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d, esperava 404: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "unknown_machine") {
		t.Errorf("corpo = %s, esperava unknown_machine", rec.Body.String())
	}
}

// A máquina "local" é o próprio hub: existe na lista, mas não abre terminal.
// Precisa chegar diferente de "não existe" para o app poder explicar.
func TestPTYMaquinaSemTerminalE501(t *testing.T) {
	rec := pedePTY(t, &fakeLauncher{shellErr: launcher.ErrNoShell})
	if rec.Code != http.StatusNotImplemented {
		t.Fatalf("status %d, esperava 501: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "no_shell") {
		t.Errorf("corpo = %s, esperava no_shell", rec.Body.String())
	}
}

// pedePTY bate na rota sem fazer upgrade — é assim que se lê o erro de HTTP.
func pedePTY(t *testing.T, f *fakeLauncher) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	req := httptest.NewRequest(http.MethodGet, "/machines/vps/pty", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, f).ServeHTTP(rec, req)
	return rec
}

// O tamanho vem de fora (query param, mensagem do app): valor ausente, zero ou
// absurdo não pode virar uma tela de 65 mil colunas nem uma divisão por zero do
// outro lado.
func TestTamanhoDeTerminalForaDaFaixaCaiNoPadrao(t *testing.T) {
	casos := []struct {
		nome, cols, rows string
		querCols         int
		querRows         int
	}{
		{"vazio", "", "", ptyDefCols, ptyDefRows},
		{"não é número", "oi", "tchau", ptyDefCols, ptyDefRows},
		{"zero", "0", "0", ptyDefCols, ptyDefRows},
		{"negativo", "-1", "-1", ptyDefCols, ptyDefRows},
		{"grande demais", "99999", "99999", ptyDefCols, ptyDefRows},
		{"no limite de baixo", "20", "4", 20, 4},
		{"no limite de cima", "500", "300", 500, 300},
		{"normal", "120", "45", 120, 45},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			cols, rows := ptySize(c.cols, c.rows)
			if cols != c.querCols || rows != c.querRows {
				t.Errorf("ptySize(%q,%q) = %d,%d — quero %d,%d", c.cols, c.rows, cols, rows, c.querCols, c.querRows)
			}
		})
	}
}
