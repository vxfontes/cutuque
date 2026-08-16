package server

import (
	"bufio"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// O log de acesso existe por causa da caixa pública do review da App Store: sem
// ele não há como saber se o revisor chegou a conectar, se digitou o token
// errado ou se a caixa estava dormindo quando ele tentou. O Render no plano
// Hobby NÃO oferece HTTP request logs (é recurso de Pro pra cima), então quem
// não imprime é quem não aparece.
//
// Duas linhas que este arquivo não cruza:
//
//  1. NUNCA loga a query string. O token do WebSocket viaja nela (SEC-003):
//     logar `path?token=...` escreveria o CUTUQUE_TOKEN dentro do log do
//     Render, que é o mesmo vazamento do /dashboard que o modo público fechou.
//  2. NUNCA loga conteúdo de sessão. "Alguém abriu um PTY às 14:32" é log de
//     acesso; o que a pessoa digitou é outra categoria, e não é da nossa conta.
const (
	// maxUsageRecent é quantos requests o /dev/usage devolve no `recent`.
	maxUsageRecent = 200
	// maxUsageClients trava o mapa de clientes: a caixa é pública e um scanner
	// com User-Agent aleatório por request encheria a memória de 512 MB.
	maxUsageClients = 50
	// maxUAChars corta User-Agent gigante antes de guardar.
	maxUAChars = 160
)

// usageEntry é um request registrado.
type usageEntry struct {
	At     time.Time `json:"at"`
	IP     string    `json:"ip"`
	Method string    `json:"method"`
	Path   string    `json:"path"`
	Status int       `json:"status"`
	DurMS  int64     `json:"dur_ms"`
	UA     string    `json:"ua,omitempty"`
}

// usageClient agrega o que um par IP+User-Agent fez. É a visão que responde
// "quem esteve aqui": o app da revisora, o pinger e o scanner ficam em linhas
// separadas.
type usageClient struct {
	IP       string         `json:"ip"`
	UA       string         `json:"ua,omitempty"`
	Requests int            `json:"requests"`
	First    time.Time      `json:"first"`
	Last     time.Time      `json:"last"`
	Statuses map[string]int `json:"statuses"`
}

// usageRecorder guarda o resumo em memória servido pelo /dev/usage. Memória e
// não disco de propósito: no Render free não existe disco, e o resumo morre no
// restart junto com o resto (sessões, board).
type usageRecorder struct {
	mu       sync.Mutex
	since    time.Time
	total    int
	health   int
	recent   []usageEntry
	clients  map[string]*usageClient
	omitidos int
}

func newUsageRecorder(since time.Time) *usageRecorder {
	return &usageRecorder{since: since, clients: map[string]*usageClient{}}
}

// record contabiliza um request.
//
// O /health fica FORA do `recent` e dos clientes, e vira só um contador: o
// pinger externo bate a cada 10 min, e sem essa exceção as últimas 200 linhas
// seriam 200 pings e nenhum revisor. O contador continua ali porque é a prova
// de que o pinger está vivo.
func (u *usageRecorder) record(e usageEntry) {
	u.mu.Lock()
	defer u.mu.Unlock()

	u.total++
	if e.Path == "/health" {
		u.health++
		return
	}

	u.recent = append(u.recent, e)
	if len(u.recent) > maxUsageRecent {
		u.recent = u.recent[len(u.recent)-maxUsageRecent:]
	}

	chave := e.IP + "\x00" + e.UA
	c, ok := u.clients[chave]
	if !ok {
		if len(u.clients) >= maxUsageClients {
			u.omitidos++
			return
		}
		c = &usageClient{IP: e.IP, UA: e.UA, First: e.At, Statuses: map[string]int{}}
		u.clients[chave] = c
	}
	c.Requests++
	c.Last = e.At
	c.Statuses[strconv.Itoa(e.Status)]++
}

// usageReport é o corpo do GET /dev/usage.
type usageReport struct {
	Since          time.Time     `json:"since"`
	UptimeS        int64         `json:"uptime_s"`
	Total          int           `json:"total"`
	HealthChecks   int           `json:"health_checks"`
	Clients        []usageClient `json:"clients"`
	ClientsOmitted int           `json:"clients_omitted,omitempty"`
	Recent         []usageEntry  `json:"recent"`
}

// report tira uma cópia do estado, com os clientes do mais recente pro mais
// antigo e o `recent` do mais novo pro mais velho (é a ordem em que se lê).
func (u *usageRecorder) report(agora time.Time) usageReport {
	u.mu.Lock()
	defer u.mu.Unlock()

	clientes := make([]usageClient, 0, len(u.clients))
	for _, c := range u.clients {
		copia := *c
		copia.Statuses = make(map[string]int, len(c.Statuses))
		for k, v := range c.Statuses {
			copia.Statuses[k] = v
		}
		clientes = append(clientes, copia)
	}
	sort.Slice(clientes, func(i, j int) bool { return clientes[i].Last.After(clientes[j].Last) })

	recentes := make([]usageEntry, 0, len(u.recent))
	for i := len(u.recent) - 1; i >= 0; i-- {
		recentes = append(recentes, u.recent[i])
	}

	return usageReport{
		Since:          u.since,
		UptimeS:        int64(agora.Sub(u.since).Seconds()),
		Total:          u.total,
		HealthChecks:   u.health,
		Clients:        clientes,
		ClientsOmitted: u.omitidos,
		Recent:         recentes,
	}
}

// usageHandler serve o resumo de uso. Vai atrás de requireAuth: são metadados de
// quem bateu na caixa, não é coisa de rota aberta.
func usageHandler(u *usageRecorder) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(u.report(time.Now()))
	}
}

// statusWriter embrulha o ResponseWriter só pra saber com que status a resposta
// saiu.
//
// O cuidado real aqui é não quebrar o WebSocket. O coder/websocket precisa
// sequestrar a conexão, e acha o Hijacker com um walker próprio (hijack.go:22):
// testa http.Hijacker no writer e, se não achar, desce pelo Unwrap. Embrulho que
// não oferece NENHUM dos dois derruba o handshake com 501 e mata o PTY — que é a
// razão da caixa pública existir.
//
// Os dois estão implementados de propósito: Hijack é o que de fato dispara aqui
// (o walker testa ele primeiro), Unwrap é o caminho que o http.ResponseController
// da stdlib usa e cobre quem embrulhar isto de novo amanhã. Um sozinho basta —
// por isso remover só um NÃO faz o teste falhar; foi preciso remover os dois pra
// ver TestAccessLogNaoQuebraOTerminal quebrar com 501.
type statusWriter struct {
	http.ResponseWriter
	status   int
	hijacked bool
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("responsewriter de baixo não é Hijacker")
	}
	c, rw, err := h.Hijack()
	if err == nil {
		w.hijacked = true
		if w.status == 0 {
			// O 101 sai escrito direto na conexão sequestrada, sem passar pelo
			// WriteHeader — sem isto o upgrade apareceria no log como status 0.
			w.status = http.StatusSwitchingProtocols
		}
	}
	return c, rw, err
}

// clientIP devolve o IP de quem chamou.
//
// Atrás do proxy do Render o RemoteAddr é o proxy, não o cliente — o IP de
// verdade vem no X-Forwarded-For. É um header, ou seja, forjável por quem
// quiser; serve pra separar visitantes num log de demo, não pra decidir acesso.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			xff = xff[:i]
		}
		if ip := strings.TrimSpace(xff); ip != "" {
			return ip
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

func encurta(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// withAccessLog imprime uma linha por request e alimenta o /dev/usage.
func withAccessLog(logger *slog.Logger, u *usageRecorder, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		inicio := time.Now()
		ip := clientIP(r)
		ua := encurta(r.Header.Get("User-Agent"), maxUAChars)

		// Upgrade só termina quando a sessão FECHA, e a linha de baixo só sai
		// depois disso — um terminal aberto há 20 min não apareceria em lugar
		// nenhum. Esta linha avisa na hora que abriu.
		upgrade := strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
		if upgrade {
			logger.Info("req abriu", "ip", ip, "metodo", r.Method, "path", r.URL.Path, "ua", ua)
		}

		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)

		dur := time.Since(inicio)
		// Path sem query: o token do WS viaja em `?token=` (SEC-003).
		e := usageEntry{
			At: inicio.UTC(), IP: ip, Method: r.Method, Path: r.URL.Path,
			Status: sw.status, DurMS: dur.Milliseconds(), UA: ua,
		}
		u.record(e)
		logger.Info("req", "ip", ip, "metodo", e.Method, "path", e.Path,
			"status", e.Status, "ms", e.DurMS, "ua", ua)
	})
}
