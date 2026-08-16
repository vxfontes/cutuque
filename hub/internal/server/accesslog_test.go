package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// bufSeguro é o destino do logger nos testes.
//
// Precisa de mutex por causa do WebSocket: a linha de fechamento sai na goroutine
// do servidor quando a sessão morre, enquanto a assertion lê o buffer aqui. Com
// bytes.Buffer pelado isso é corrida de verdade, e o -race pega.
type bufSeguro struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *bufSeguro) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *bufSeguro) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// logDeTeste devolve um logger que escreve num buffer legível.
func logDeTeste() (*slog.Logger, *bufSeguro) {
	buf := &bufSeguro{}
	return slog.New(slog.NewTextHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})), buf
}

// baterCom faz um request contra um router com log de acesso ligado e devolve o
// que foi impresso.
func baterCom(t *testing.T, req *http.Request) (*httptest.ResponseRecorder, string) {
	t.Helper()
	logger, buf := logDeTeste()
	cfg, reg := testDeps()
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithAccessLog(logger)).ServeHTTP(rec, req)
	return rec, buf.String()
}

func TestAccessLogImprimeUmaLinhaPorRequest(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/sessions", nil)
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("User-Agent", "CutuqueApp/2.7.4")

	rec, saida := baterCom(t, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	for _, quero := range []string{"/sessions", "status=200", "CutuqueApp/2.7.4", "GET"} {
		if !strings.Contains(saida, quero) {
			t.Errorf("log não trouxe %q; saiu:\n%s", quero, saida)
		}
	}
}

// A regra mais importante deste arquivo. O token do WS viaja na query string
// (SEC-003); logar path+query escreveria o CUTUQUE_TOKEN dentro do log do
// Render — o mesmo vazamento que o modo público fechou no /dashboard.
func TestAccessLogNuncaEscreveAQueryString(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/sessions?token=segredo-do-hub&cols=100", nil)
	req.Header.Set("Authorization", "Bearer secret")

	_, saida := baterCom(t, req)

	if strings.Contains(saida, "segredo-do-hub") {
		t.Fatalf("O TOKEN VAZOU PRO LOG. saída:\n%s", saida)
	}
	if strings.Contains(saida, "cols=100") {
		t.Errorf("a query inteira tem que ficar de fora, não só o token; saiu:\n%s", saida)
	}
	if !strings.Contains(saida, "/sessions") {
		t.Errorf("o path devia continuar aparecendo; saiu:\n%s", saida)
	}
}

func TestAccessLogGuardaOStatusDeErro(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/sessions", nil) // sem token

	rec, saida := baterCom(t, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
	// É este 401 que conta a história "o revisor digitou o token errado".
	if !strings.Contains(saida, "status=401") {
		t.Errorf("log não trouxe o 401; saiu:\n%s", saida)
	}
}

func TestClientIPPrefereOXForwardedFor(t *testing.T) {
	casos := []struct {
		nome, xff, remote, quero string
	}{
		{"sem xff cai no RemoteAddr", "", "10.0.0.9:5555", "10.0.0.9"},
		{"xff simples", "203.0.113.7", "10.0.0.9:5555", "203.0.113.7"},
		{"cadeia de proxies usa o primeiro", "203.0.113.7, 70.41.3.18", "10.0.0.9:5555", "203.0.113.7"},
		{"espaços não contam", "  203.0.113.7  ", "10.0.0.9:5555", "203.0.113.7"},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/health", nil)
			r.RemoteAddr = c.remote
			if c.xff != "" {
				r.Header.Set("X-Forwarded-For", c.xff)
			}
			if got := clientIP(r); got != c.quero {
				t.Errorf("clientIP = %q, quero %q", got, c.quero)
			}
		})
	}
}

// O pinger externo bate no /health a cada 10 min. Sem esta exceção as últimas
// 200 linhas do /dev/usage seriam 200 pings e nenhum revisor.
func TestUsageDeixaOHealthForaDoRecenteMasConta(t *testing.T) {
	u := newUsageRecorder(time.Now())
	agora := time.Now()
	for i := 0; i < 3; i++ {
		u.record(usageEntry{At: agora, IP: "1.2.3.4", Method: "GET", Path: "/health", Status: 200})
	}
	u.record(usageEntry{At: agora, IP: "5.6.7.8", Method: "GET", Path: "/sessions", Status: 200})

	r := u.report(agora)
	if r.Total != 4 {
		t.Errorf("Total = %d, quero 4 (o health conta no total)", r.Total)
	}
	if r.HealthChecks != 3 {
		t.Errorf("HealthChecks = %d, quero 3", r.HealthChecks)
	}
	if len(r.Recent) != 1 || r.Recent[0].Path != "/sessions" {
		t.Errorf("Recent = %+v, quero só o /sessions", r.Recent)
	}
	if len(r.Clients) != 1 || r.Clients[0].IP != "5.6.7.8" {
		t.Errorf("Clients = %+v, quero só quem não é pinger", r.Clients)
	}
}

func TestUsageAgrupaPorClienteEContaStatus(t *testing.T) {
	u := newUsageRecorder(time.Now())
	agora := time.Now()
	u.record(usageEntry{At: agora, IP: "1.1.1.1", UA: "CutuqueApp", Method: "GET", Path: "/sessions", Status: 401})
	u.record(usageEntry{At: agora.Add(time.Second), IP: "1.1.1.1", UA: "CutuqueApp", Method: "GET", Path: "/sessions", Status: 200})
	u.record(usageEntry{At: agora.Add(2 * time.Second), IP: "9.9.9.9", UA: "curl/8", Method: "GET", Path: "/board", Status: 200})

	r := u.report(agora)
	if len(r.Clients) != 2 {
		t.Fatalf("len(Clients) = %d, quero 2", len(r.Clients))
	}
	// Mais recente primeiro.
	if r.Clients[0].IP != "9.9.9.9" {
		t.Errorf("Clients[0].IP = %q, quero o mais recente (9.9.9.9)", r.Clients[0].IP)
	}
	app := r.Clients[1]
	if app.Requests != 2 {
		t.Errorf("Requests = %d, quero 2", app.Requests)
	}
	if app.Statuses["401"] != 1 || app.Statuses["200"] != 1 {
		t.Errorf("Statuses = %v, quero um 401 e um 200", app.Statuses)
	}
}

// Caixa pública: um scanner com User-Agent novo a cada request encheria os
// 512 MB. O mapa tem teto, e o que passou dele é contado à parte em vez de
// desaparecer em silêncio.
func TestUsageTravaOMapaDeClientes(t *testing.T) {
	u := newUsageRecorder(time.Now())
	agora := time.Now()
	for i := 0; i < maxUsageClients+7; i++ {
		u.record(usageEntry{At: agora, IP: "1.1.1.1", UA: string(rune('a'+i%26)) + strings.Repeat("x", i), Path: "/board", Status: 200})
	}
	r := u.report(agora)
	if len(r.Clients) != maxUsageClients {
		t.Errorf("len(Clients) = %d, quero o teto %d", len(r.Clients), maxUsageClients)
	}
	if r.ClientsOmitted != 7 {
		t.Errorf("ClientsOmitted = %d, quero 7", r.ClientsOmitted)
	}
	if r.Total != maxUsageClients+7 {
		t.Errorf("Total = %d, quero contar todo mundo mesmo com o teto", r.Total)
	}
}

// User-Agent é header, e header é do cliente: numa caixa pública, 5 KB de UA por
// request vira 5 KB por linha de log e por entrada guardada.
func TestUsageCortaUserAgentGigante(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("User-Agent", strings.Repeat("A", 5000))

	_, saida := baterCom(t, req)

	if strings.Contains(saida, strings.Repeat("A", maxUAChars+10)) {
		t.Errorf("o User-Agent não foi cortado (linha com %d bytes)", len(saida))
	}
	if !strings.Contains(saida, "…") {
		t.Errorf("faltou a marca de corte; saiu:\n%s", saida)
	}
}

func TestUsageSoExisteComOLogLigado(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodGet, "/dev/usage", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404 sem WithAccessLog", rec.Code)
	}
}

func TestUsageExigeToken(t *testing.T) {
	logger, _ := logDeTeste()
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodGet, "/dev/usage", nil) // sem token
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, WithAccessLog(logger)).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401 (são metadados de quem bateu na caixa)", rec.Code)
	}
}

func TestUsageServeORelatorio(t *testing.T) {
	logger, _ := logDeTeste()
	cfg, reg := testDeps()
	h := Router(cfg, reg, nil, WithAccessLog(logger))

	// Gera tráfego antes de perguntar.
	for _, alvo := range []string{"/sessions", "/health", "/board"} {
		r := httptest.NewRequest(http.MethodGet, alvo, nil)
		r.Header.Set("Authorization", "Bearer secret")
		r.Header.Set("User-Agent", "CutuqueApp/2.7.4")
		h.ServeHTTP(httptest.NewRecorder(), r)
	}

	req := httptest.NewRequest(http.MethodGet, "/dev/usage", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var r usageReport
	if err := json.Unmarshal(rec.Body.Bytes(), &r); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if r.HealthChecks != 1 {
		t.Errorf("HealthChecks = %d, quero 1", r.HealthChecks)
	}
	if len(r.Recent) == 0 {
		t.Fatal("Recent veio vazio")
	}
	// Mais novo primeiro: o /board foi o último request antes do /dev/usage.
	if r.Recent[0].Path != "/board" {
		t.Errorf("Recent[0].Path = %q, quero /board (mais novo primeiro)", r.Recent[0].Path)
	}
	if r.Since.IsZero() {
		t.Error("Since veio zerado — sem ele não dá pra saber a janela do resumo")
	}
}

// O teste que justifica o statusWriter ter Hijack e Unwrap: o coder/websocket
// sequestra a conexão e procura o Hijacker descendo o embrulho (hijack.go:22).
// Writer que esconde os dois derruba o handshake com 501 — e o terminal é a razão
// da caixa pública existir.
//
// Rede validada: com Hijack e Unwrap removidos este teste falha com
// "expected handshake response status code 101 but got 501". Com só um dos dois
// removido ele passa, porque a lib aceita qualquer um dos caminhos.
func TestAccessLogNaoQuebraOTerminal(t *testing.T) {
	logger, buf := logDeTeste()
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, &fakeLauncher{shellProg: "cat"}, WithAccessLog(logger)))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/machines/vps/pty?token=secret&cols=100&rows=40"
	c, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("Dial: %v — o middleware quebrou o upgrade", err)
	}
	t.Cleanup(func() { c.CloseNow() })

	if err := c.Write(ctx, websocket.MessageBinary, []byte("oi terminal\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	leAte(t, ctx, c, "oi terminal")

	// E o token da query NÃO pode ter ido pro log nem por aqui.
	if strings.Contains(buf.String(), "token=secret") || strings.Contains(buf.String(), "cols=100") {
		t.Errorf("query string vazou no log do WS:\n%s", buf.String())
	}
	// A linha de abertura sai na hora; a de fechamento só quando a sessão morre.
	if !strings.Contains(buf.String(), "req abriu") {
		t.Errorf("faltou a linha de abertura do WS (terminal aberto ficaria invisível):\n%s", buf.String())
	}
}
