package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/board"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

func TestPlausibleNext(t *testing.T) {
	cases := []struct {
		from session.State
		tick int
		want session.State
	}{
		{session.StateIdle, 0, session.StateRunning},
		{session.StateRunning, 0, session.StateNeedsYou},
		{session.StateRunning, 1, session.StateDone},
		{session.StateRunning, 2, session.StateError},
		{session.StateRunning, 3, session.StateNeedsYou}, // cicla
		{session.StateNeedsYou, 0, session.StateRunning},
		{session.StateDone, 0, session.StateRunning},
		{session.StateError, 0, session.StateRunning},
	}
	for _, c := range cases {
		if got := plausibleNext(c.from, c.tick); got != c.want {
			t.Errorf("plausibleNext(%q, %d) = %q, quero %q", c.from, c.tick, got, c.want)
		}
	}
}

func TestSeedDriverStepAdvancesOneSession(t *testing.T) {
	reg := registry.New()
	now := time.Date(2026, 7, 2, 10, 0, 0, 0, time.UTC)
	reg.Add(session.Session{ID: "seed-1", State: session.StateRunning, CreatedAt: now, UpdatedAt: now})
	reg.Add(session.Session{ID: "seed-2", State: session.StateRunning, CreatedAt: now.Add(time.Minute), UpdatedAt: now})

	d := newSeedDriver(reg, []string{"seed-1", "seed-2"})
	d.step() // avança seed-1 com tick 0: running -> needs_you

	got, _ := reg.Get("seed-1")
	if got.State != session.StateNeedsYou {
		t.Errorf("seed-1 State = %q, quero \"needs_you\"", got.State)
	}
	// seed-2 ainda não foi tocada.
	if s, _ := reg.Get("seed-2"); s.State != session.StateRunning {
		t.Errorf("seed-2 State = %q, quero \"running\" (round-robin)", s.State)
	}

	d.step() // avança seed-2 com tick 1: running -> done
	if s, _ := reg.Get("seed-2"); s.State != session.StateDone {
		t.Errorf("seed-2 State = %q, quero \"done\"", s.State)
	}
}

func TestSeedHandlerDevReturnsFourSessions(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var body struct {
		Sessions []session.Session `json:"sessions"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Sessions) != 4 {
		t.Fatalf("len(sessions) = %d, quero 4", len(body.Sessions))
	}

	machines := map[string]bool{}
	agents := map[string]bool{}
	for _, s := range body.Sessions {
		machines[s.Machine] = true
		agents[s.Agent] = true
	}
	for _, m := range []string{"macbook", "desktop-win"} {
		if !machines[m] {
			t.Errorf("máquina %q ausente no seed", m)
		}
	}
	for _, a := range []string{"claude-code", "codex"} {
		if !agents[a] {
			t.Errorf("agente %q ausente no seed", a)
		}
	}

	// As sessões devem ter sido registradas no registry.
	if len(reg.List()) != 4 {
		t.Errorf("registry tem %d sessões, quero 4", len(reg.List()))
	}
}

func TestSeedHandlerProdReturns404(t *testing.T) {
	cfg, reg := testDeps()
	cfg.Env = "prod"

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret") // auth ok; deve cair no 404
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, quero 404 (seed é dev-only)", rec.Code)
	}
}

func TestSeedRequiresAuth(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil) // sem token
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, quero 401", rec.Code)
	}
}

func TestSeedBoardEspalhaPelasCincoColunas(t *testing.T) {
	tasks := seedBoard(board.New())

	if len(tasks) != len(seedCards) {
		t.Fatalf("len(tasks) = %d, quero %d", len(tasks), len(seedCards))
	}
	porColuna := map[string]int{}
	for _, task := range tasks {
		porColuna[task.Column]++
	}
	for _, col := range []string{"a_fazer", "em_progresso", "feito", "em_revisao", "concluido"} {
		if porColuna[col] == 0 {
			t.Errorf("coluna %q ficou vazia no seed (o revisor abre o quadro e vê buraco)", col)
		}
	}
}

// O card não salta pra coluna final: ele percorre o caminho, e é isso que faz o
// hub derivar as datas. Sem isso o card aparece "concluído" sem nunca ter começado.
func TestSeedBoardDerivaAsDatasDoCaminho(t *testing.T) {
	for _, task := range seedBoard(board.New()) {
		switch task.Column {
		case "concluido":
			if task.EndedAt == nil {
				t.Errorf("%q está em concluido sem ended_at", task.Title)
			}
			fallthrough
		case "em_revisao":
			if task.ReviewedAt == nil {
				t.Errorf("%q passou por em_revisao sem reviewed_at", task.Title)
			}
			fallthrough
		case "feito", "em_progresso":
			if task.StartedAt == nil {
				t.Errorf("%q saiu de a_fazer sem started_at", task.Title)
			}
		}
	}
}

func TestSeedBoardNaoDuplicaNemPisaEmQuadroExistente(t *testing.T) {
	st := board.New()

	primeira := seedBoard(st)
	segunda := seedBoard(st)

	if len(segunda) != len(primeira) {
		t.Fatalf("2ª chamada deixou %d cards, quero os mesmos %d (Add gera id novo: duplicaria)", len(segunda), len(primeira))
	}
	if len(st.List()) != len(seedCards) {
		t.Fatalf("store tem %d cards depois de 2 seeds, quero %d", len(st.List()), len(seedCards))
	}

	// Quadro que já tem trabalho de verdade não recebe card de mentira.
	real := board.New()
	real.Add(board.NewTask{Title: "trabalho de verdade"})
	if got := seedBoard(real); len(got) != 1 || got[0].Title != "trabalho de verdade" {
		t.Fatalf("seedBoard mexeu num quadro já populado: %+v", got)
	}
}

func TestSeedBoardComStoreNil(t *testing.T) {
	if got := seedBoard(nil); got != nil {
		t.Fatalf("seedBoard(nil) = %+v, quero nil (hub sem quadro não pode quebrar o seed)", got)
	}
}

// O revisor vê o mesmo trabalho na aba de sessões e no quadro — é assim que o app
// funciona de verdade, e é o que torna o demo legível.
func TestSeedSessoesECardsContamAMesmaHistoria(t *testing.T) {
	titulos := map[string]bool{}
	for _, c := range seedCards {
		titulos[strings.ToLower(c.title)] = true
	}
	for _, s := range seedSessions(time.Now()) {
		if !titulos[strings.ToLower(s.Title)] {
			t.Errorf("sessão %q não tem card correspondente no quadro", s.Title)
		}
	}
}

func TestSeedHandlerSemeiaOQuadro(t *testing.T) {
	cfg, reg := testDeps()
	st := board.New()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil, WithBoard(st)).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var body struct {
		Sessions []session.Session `json:"sessions"`
		Tasks    []board.Task      `json:"tasks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Sessions) != 4 {
		t.Errorf("len(sessions) = %d, quero 4", len(body.Sessions))
	}
	if len(body.Tasks) != len(seedCards) {
		t.Errorf("len(tasks) = %d, quero %d", len(body.Tasks), len(seedCards))
	}
	if len(st.List()) != len(seedCards) {
		t.Errorf("store tem %d cards, quero %d", len(st.List()), len(seedCards))
	}
}

// Hub sem quadro (Router sem WithBoard): o seed de sessão continua de pé.
func TestSeedHandlerSemQuadroSegueSemeandoSessao(t *testing.T) {
	cfg, reg := testDeps()

	req := httptest.NewRequest(http.MethodPost, "/dev/seed", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()

	Router(cfg, reg, nil).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, quero 200", rec.Code)
	}
	var body struct {
		Sessions []session.Session `json:"sessions"`
		Tasks    []board.Task      `json:"tasks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON: %v", err)
	}
	if len(body.Sessions) != 4 {
		t.Errorf("len(sessions) = %d, quero 4", len(body.Sessions))
	}
	if len(body.Tasks) != 0 {
		t.Errorf("len(tasks) = %d, quero 0 (não há store)", len(body.Tasks))
	}
}
