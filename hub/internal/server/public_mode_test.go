package server

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/board"
)

// rotaPublica dispara uma requisição contra um Router montado com (ou sem) o
// modo público e devolve o recorder. O board entra sempre — as rotas /board só
// existem quando há store.
func rotaPublica(t *testing.T, publico bool, metodo, alvo string, corpo string) *httptest.ResponseRecorder {
	t.Helper()
	cfg, reg := testDeps()
	opts := []RouterOption{WithBoard(board.New())}
	if publico {
		opts = append(opts, WithPublicMode())
	}
	var body *bytes.Buffer
	if corpo != "" {
		body = bytes.NewBufferString(corpo)
	} else {
		body = &bytes.Buffer{}
	}
	rec := httptest.NewRecorder()
	Router(cfg, reg, nil, opts...).ServeHTTP(rec, httptest.NewRequest(metodo, alvo, body))
	return rec
}

// TestDashboardVazaOTokenSemModoPublico não testa o modo público: testa a razão
// dele existir. Se um dia o /dashboard parar de injetar o token no HTML, este
// teste falha e o WithPublicMode perde metade do motivo — é para essa conversa
// acontecer que ele está aqui, e não para proteger o comportamento.
func TestDashboardVazaOTokenSemModoPublico(t *testing.T) {
	rec := rotaPublica(t, false, http.MethodGet, "/dashboard", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /dashboard sem modo público = %d, quero 200 (é o hub de casa)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "secret") {
		t.Fatal("o /dashboard não trouxe mais o token no HTML; ver se o WithPublicMode ainda precisa cobrir esta rota")
	}
}

func TestModoPublicoNaoRegistraODashboard(t *testing.T) {
	rec := rotaPublica(t, true, http.MethodGet, "/dashboard", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("GET /dashboard no modo público = %d, quero 404 (a rota não pode existir)", rec.Code)
	}
	// O que importa não é o status e sim o token: 404 com o token no corpo
	// continuaria sendo vazamento.
	if strings.Contains(rec.Body.String(), "secret") {
		t.Fatal("o token do hub apareceu na resposta do /dashboard no modo público")
	}
}

func TestModoPublicoNaoRegistraOIconeDoDashboard(t *testing.T) {
	if rec := rotaPublica(t, true, http.MethodGet, "/dashboard-icon.png", ""); rec.Code != http.StatusNotFound {
		t.Fatalf("GET /dashboard-icon.png no modo público = %d, quero 404", rec.Code)
	}
	if rec := rotaPublica(t, false, http.MethodGet, "/dashboard-icon.png", ""); rec.Code != http.StatusOK {
		t.Fatalf("GET /dashboard-icon.png sem modo público = %d, quero 200", rec.Code)
	}
}

// TestModoPublicoTiraAEscritaDoBoard cobre as três rotas que gravam no Kanban
// sem pedir token nenhum. 404 aqui é o resultado desejado: a rota não existe.
func TestModoPublicoTiraAEscritaDoBoard(t *testing.T) {
	casos := []struct {
		nome, metodo, alvo, corpo string
	}{
		{"criar", http.MethodPost, "/board/tasks", `{"title":"x","group":"g","session":"s"}`},
		{"mover", http.MethodPatch, "/board/tasks/abc", `{"column":"feito"}`},
		{"comentar", http.MethodPost, "/board/tasks/abc/comments", `{"text":"oi","agent":"a"}`},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			// 404 OU 405, e os dois servem: o que importa é não chegar no handler.
			// O PATCH dá 405 e não 404 porque o DELETE continua registrado no MESMO
			// padrão (/board/tasks/{id}) — o ServeMux acha o caminho, não acha o
			// método, e responde "método não permitido". A rota de escrita sumiu do
			// mesmo jeito.
			rec := rotaPublica(t, true, c.metodo, c.alvo, c.corpo)
			if rec.Code != http.StatusNotFound && rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s %s no modo público = %d, quero 404 ou 405", c.metodo, c.alvo, rec.Code)
			}
			// Sem o modo, a mesma chamada tem que continuar chegando no handler.
			// Qualquer coisa MENOS 404 serve: o card "abc" não existe, então
			// mover/comentar respondem 404 do STORE — por isso só o criar dá para
			// afirmar com um status exato.
			rec = rotaPublica(t, false, c.metodo, c.alvo, c.corpo)
			if c.nome == "criar" && rec.Code != http.StatusCreated {
				t.Fatalf("%s %s sem modo público = %d, quero 201", c.metodo, c.alvo, rec.Code)
			}
		})
	}
}

// TestModoPublicoDeixaALeituraDoBoardEmPe — um board público em leitura é uma
// página; em escrita é um mural. A demo mostra o quadro, e é de propósito.
func TestModoPublicoDeixaALeituraDoBoardEmPe(t *testing.T) {
	for _, alvo := range []string{"/board", "/board/stats", "/board/search?q=x", "/board/archive"} {
		if rec := rotaPublica(t, true, http.MethodGet, alvo, ""); rec.Code != http.StatusOK {
			t.Errorf("GET %s no modo público = %d, quero 200", alvo, rec.Code)
		}
	}
}

// TestModoPublicoNaoDerrubaOHealth — o healthcheck do provedor bate aqui, e o
// pinger que mantém a caixa acordada também. Derrubar esta rota derrubaria a
// caixa inteira.
func TestModoPublicoNaoDerrubaOHealth(t *testing.T) {
	if rec := rotaPublica(t, true, http.MethodGet, "/health", ""); rec.Code != http.StatusOK {
		t.Fatalf("GET /health no modo público = %d, quero 200", rec.Code)
	}
}

// TestModoPublicoNaoMexeNasRotasComToken — o modo tira rotas SEM autenticação; o
// que já era protegido segue protegido, e do mesmo jeito. Sem token: 401, não
// 404 (404 aqui significaria que o modo comeu rota que não era dele).
func TestModoPublicoNaoMexeNasRotasComToken(t *testing.T) {
	// /machines fica de fora daqui de propósito: ela só existe com WithMachines,
	// que este helper não passa, então daria 404 por ausência de opção e não por
	// causa do modo — o teste pareceria pegar uma regressão que não existe.
	if rec := rotaPublica(t, true, http.MethodGet, "/sessions", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("GET /sessions sem token no modo público = %d, quero 401", rec.Code)
	}
	if rec := rotaPublica(t, true, http.MethodDelete, "/board/tasks/abc", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("DELETE /board/tasks no modo público = %d, quero 401 (já exigia token antes)", rec.Code)
	}
}
