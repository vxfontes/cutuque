// Package integration exercita o fluxo completo da Fase 3:
// REST (POST /sessions, /approve) → Launcher → Runner (fake) → State Engine →
// Registry → Command API (WebSocket), incluindo o control_response de aprovação.
package integration

import (
	"bufio"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/config"
	"github.com/vxfontes/cutuque/hub/internal/engine"
	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/registry"
	"github.com/vxfontes/cutuque/hub/internal/server"
	"github.com/vxfontes/cutuque/hub/internal/session"
)

const (
	sid   = "int-sess-1"
	reqID = "int-req-1"
)

// scriptTarget é um Target fake que emite init + control_request, espera o
// control_response e então emite o result — simulando um Claude Code que pede
// permissão e prossegue após a aprovação.
type scriptTarget struct{ name string }

func (s scriptTarget) Name() string { return s.name }
func (s scriptTarget) Kind() string { return "claude-code" }
func (s scriptTarget) NewRunner(app claudecode.Applier) *claudecode.Runner {
	return claudecode.NewRunner(app)
}
func (s scriptTarget) Start(_ context.Context, _, _, _, _, _, prompt string) (*claudecode.Handle, error) {
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	go func() {
		defer stdoutW.Close()
		in := bufio.NewReader(stdinR)
		_, _ = in.ReadString('\n') // prompt inicial
		_, _ = io.WriteString(stdoutW, `{"type":"system","subtype":"init","session_id":"`+sid+`"}`+"\n")
		_, _ = io.WriteString(stdoutW, `{"type":"control_request","request_id":"`+reqID+`","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch cutuque-int.txt","description":"probe"},"description":"probe"}}`+"\n")
		_, _ = in.ReadString('\n') // aguarda o control_response
		_, _ = io.WriteString(stdoutW, `{"type":"result","subtype":"success","is_error":false,"result":"feito"}`+"\n")
	}()
	h := &claudecode.Handle{Stdout: stdoutR, Stdin: stdinW}
	if prompt != "" {
		if err := h.SendUserMessage(prompt); err != nil {
			return nil, err
		}
	}
	return h, nil
}

func TestLaunchApproveFlowEndToEnd(t *testing.T) {
	reg := registry.New()
	eng := engine.New(reg)
	lch := launcher.New(eng, reg, map[string]map[string]claudecode.Target{
		"macbook": {"claude-code": scriptTarget{name: "macbook"}},
	})
	cfg := config.Config{Env: "dev", Token: "secret"}

	srv := httptest.NewServer(server.Router(cfg, reg, lch))
	defer srv.Close()

	// [16/08/2026] Um orçamento só para o teste inteiro: era um WithTimeout de
	// 10s fixo, e o teto das esperas por evento (safetyDeadline) é outro número.
	// Dois relógios diferentes no mesmo teste significam que o menor mata o
	// maior no meio do caminho — o ctx expiraria, a goroutine leitora do WS
	// pararia, e a seção 5 falharia dizendo "faltou mensagem" quando o que
	// houve foi orçamento incoerente. Derivando os dois de safetyDeadline(t),
	// tudo neste teste morre na mesma hora, e essa hora vem do -timeout do
	// próprio `go test` (ver safetyDeadline).
	ctx, cancel := context.WithDeadline(context.Background(), safetyDeadline(t))
	defer cancel()

	// WS conectado antes do launch, para observar toda a evolução.
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws?token=secret"
	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	type wsMsg struct {
		Type    string          `json:"type"`
		Session session.Session `json:"session"`
	}
	msgs := make(chan wsMsg, 128)
	go func() {
		for {
			var m wsMsg
			if err := wsjson.Read(ctx, c, &m); err != nil {
				return
			}
			msgs <- m
		}
	}()

	// [16/08/2026] Espera o snapshot ANTES de lançar. Sem isto o teste tem uma
	// corrida de partida que a carga expõe: websocket.Dial devolve quando o
	// handshake HTTP termina (dentro do websocket.Accept), e o reg.Subscribe()
	// do WSHandler só acontece DEPOIS disso. Na janela entre os dois, o launch
	// pode disparar e as transições (running, needs_you) irem para o broadcast
	// sem que este cliente esteja assinado — a seção 5 falhava com "WS não
	// mostrou session_updated running/needs_you/done" mesmo com o pipeline
	// perfeito, e o `defer srv.Close()` ainda por cima não espera goroutine de
	// conexão sequestrada.
	//
	// O snapshot é o sinal certo, e não mais um sleep, porque o WSHandler
	// assina ANTES de enviá-lo (comentário "Assina ANTES do snapshot" em
	// ws.go): recebê-lo PROVA que a assinatura já existe, então nada do que
	// vier depois do launch se perde.
esperaSnapshot:
	for {
		select {
		case m := <-msgs:
			if m.Type == "snapshot" {
				break esperaSnapshot
			}
		case <-ctx.Done():
			t.Fatal("WS não entregou o snapshot inicial dentro do teto de segurança")
		}
	}

	// 1) Lança pela REST.
	launchBody := `{"machine":"macbook","agent":"claude-code","prompt":"crie um arquivo de prova"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/sessions", strings.NewReader(launchBody))
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST /sessions: %v", err)
	}
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("launch status = %d, quero 201", resp.StatusCode)
	}
	resp.Body.Close()

	// 2) Espera needs_you COM pending_prompt (invariante: exibir antes de aprovar).
	//
	// [16/08/2026] A condição precisa incluir o prompt, não só o estado. O
	// Engine chega em needs_you em escritas SEPARADAS e nessa ordem
	// (engine.go, no bloco `if target == session.StateNeedsYou`):
	// UpdateStateIfCurrent → SetPendingQuestions → SetPendingPrompt. Cada uma
	// faz seu próprio broadcast, então o PRIMEIRO evento de needs_you sai com
	// PendingPrompt ainda vazio e o texto só chega no broadcast seguinte —
	// convergência por desenho, não defeito: o próprio comentário do engine
	// diz que "o push de needs_you dispara no broadcast do PendingPrompt".
	//
	// O poll de 3ms de antes escondia isso por acidente (dormia mais do que a
	// janela durava). Esperar por evento acorda exatamente dentro dela, e é por
	// isso que o teste seguia falhando sob carga em "PendingPrompt = ''" mesmo
	// depois de trocar o relógio pelo Subscribe. Assertar o estado sozinho
	// testaria uma promessa que o sistema não faz; a promessa real — e a que
	// importa pra usuária — é que quando a linha aparece como "precisa de
	// você", o texto está lá. É essa que se espera aqui.
	waitCond(ctx, t, reg, sid, "needs_you com o resumo do pedido", func(s session.Session) bool {
		return s.State == session.StateNeedsYou && strings.HasPrefix(s.PendingPrompt, "Bash:")
	})

	// 3) Aprova pela REST.
	areq, _ := http.NewRequest(http.MethodPost, srv.URL+"/sessions/"+sid+"/approve", nil)
	areq.Header.Set("Authorization", "Bearer secret")
	aresp, err := http.DefaultClient.Do(areq)
	if err != nil {
		t.Fatalf("POST approve: %v", err)
	}
	if aresp.StatusCode != http.StatusOK {
		t.Fatalf("approve status = %d, quero 200", aresp.StatusCode)
	}
	aresp.Body.Close()

	// 4) Após aprovar: running → done, pending limpo. Mesma janela da seção 2,
	// espelhada: o ClearPendingPrompt também é escrita SEPARADA e vem DEPOIS do
	// UpdateStateIfCurrent, então o primeiro evento de `done` ainda carrega o
	// prompt antigo (era a falha "PendingPrompt = 'Bash: ...', quero vazio ao
	// terminar"). A condição, de novo, é a promessa inteira: terminou E limpou.
	waitCond(ctx, t, reg, sid, "done com o pending limpo", func(s session.Session) bool {
		return s.State == session.StateDone && s.PendingPrompt == ""
	})

	// 5) WS deve ter mostrado a evolução, incluindo needs_you COM pending_prompt.
	//
	// [16/08/2026] Isto era um SEGUNDO relógio de parede independente do de
	// waitCond — `deadline := time.After(3 * time.Second)` — que a auditoria
	// do card encontrou e o diagnóstico original nem citava (o card só falava
	// da linha do helper de espera). Sob carga (3 agentes compilando), esses 3s podiam
	// estourar antes de a goroutine leitora do WS (abaixo, que alimenta `msgs`)
	// conseguir ser escalonada, e o teste falhava dizendo "não mostrou
	// session_updated done" mesmo com o pipeline correto, só lento.
	//
	// Não dá pra trocar isto por Registry.Subscribe (como em waitCond): o que
	// se está esperando aqui não é um evento do Registry, é a CHEGADA no canal
	// `msgs`, que só existe porque a goroutine acima faz wsjson.Read(ctx, ...).
	// Só que isso revela o teto certo: aquela goroutine morre no instante em que
	// `ctx` expira (o ctx criado no início do teste, derivado de
	// safetyDeadline(t) — teto "de segurança", não critério de aprovação
	// escolhido a dedo). Depois que `ctx` expira, NADA mais chega em `msgs`,
	// então esperar além de ctx.Done() nunca ajudaria — usar ctx.Done() aqui não
	// é "outro número mágico", é o limite real do recurso que este loop consome,
	// e é o MESMO teto que waitCond usa: um orçamento só para o teste todo.
	var sawRunning, sawNeedsYouWithPrompt, sawDone bool
collect:
	for {
		select {
		case m := <-msgs:
			if m.Type != "session_updated" || m.Session.ID != sid {
				continue
			}
			switch m.Session.State {
			case session.StateRunning:
				sawRunning = true
			case session.StateNeedsYou:
				if m.Session.PendingPrompt != "" {
					sawNeedsYouWithPrompt = true
				}
			case session.StateDone:
				sawDone = true
			}
			if sawRunning && sawNeedsYouWithPrompt && sawDone {
				break collect
			}
		case <-ctx.Done():
			break collect
		}
	}
	if !sawRunning {
		t.Errorf("WS não mostrou session_updated running")
	}
	if !sawNeedsYouWithPrompt {
		t.Errorf("WS não mostrou session_updated needs_you com pending_prompt")
	}
	if !sawDone {
		t.Errorf("WS não mostrou session_updated done")
	}
}

// waitCond espera a sessão `id` satisfazer `cond`. Serve as DUAS esperas do
// teste (needs_you e done) — não é só "a linha 134", como o diagnóstico
// original do card dizia.
//
// É condição, e não estado, de propósito: o Engine chega em cada estado em
// escritas separadas (estado primeiro, campos depois), então "estado X" e
// "estado X já consistente" são instantes diferentes, e é o segundo que os
// testes querem. Ver o comentário na seção 2 do teste.
//
// [16/08/2026] Isto ERA `for time.Now().Before(deadline) { if...==want {
// return}; time.Sleep(3*time.Millisecond) }` com deadline := 3s de relógio de
// parede. O card pedia para "trocar espera de relógio por poll com condição" —
// auditado, isso está errado: isto JÁ ERA poll por condição com deadline,
// não uma espera cega. O defeito nunca foi a AUSÊNCIA de poll, foi o VALOR do
// teto: sob carga real (3 agentes compilando ao mesmo tempo — CPU-spin puro
// não reproduz, é I/O+GC+scheduling), o pipeline REST→launcher→runner(fake)→
// engine→registry pode legitimamente ultrapassar 3s de relógio de parede para
// ser escalonado, e o teste falhava por lentidão da máquina, não por defeito
// do hub. O scriptTarget em si é 100% determinístico (leitura/escrita
// bloqueante em io.Pipe, sem sleep/timer/rand) — a variância é só
// escalonamento de goroutines, então não adiantaria mexer nele.
//
// Conserto: troca o poll por relógio por espera por EVENTO no
// Registry.Subscribe (o mesmo canal que o WSHandler usa em produção, em
// ws.go, e que registry_test.go usa como padrão — referência por nome de
// função de propósito: número de linha envelhece no primeiro commit que
// mexer no arquivo vizinho). A ordem importa e é a armadilha conhecida:
// Subscribe ANTES de checar o estado atual. Se checássemos o estado primeiro
// e só depois assinássemos, uma transição que já aconteceu entre as duas
// chamadas ficaria invisível para o canal e o teste travaria para sempre
// esperando um evento que já passou. Fazendo Subscribe→Get→(loop no canal),
// ou o Get já pega o estado querido, ou o broadcast seguinte cai no canal.
//
// Ressalva honesta sobre essa garantia: o broadcast do Registry envia sem
// bloquear e DESCARTA se o buffer do assinante (subBuffer = 32) estiver
// cheio. Para este teste — uma sessão, ~4 transições, loop drenando — não há
// como encher. Se um dia isto virar helper de um cenário com muita transição
// concorrente, essa dependência precisa ser revista, senão o evento sumiria
// em silêncio e o flake voltaria por outra porta.
//
// O teto de segurança deixa de ser um número de relógio escolhido pra
// aguentar o cenário de carga (isso é o que causava o flake) e passa a ser
// o ctx do próprio teste, que nasce de t.Deadline() — o -timeout do `go
// test`, a fonte honesta de "quanto falta antes do arcabouco matar o
// processo à força". É de propósito que seja o MESMO ctx da conexão WS e não
// um timer próprio: com dois orçamentos diferentes (um de 10s no ctx, outro
// de 20s aqui), uma espera longa e legítima daqui mataria a goroutine
// leitora do WS pelo caminho, e a seção 5 falharia dizendo que faltou
// mensagem — trocar um flake por outro. Um teste, um orçamento.
// Continuamos falhando rápido em quebra de verdade: sem evento nenhum, o
// teste erra assim que o teto (não um chute de carga) se esgota.
func waitCond(ctx context.Context, t *testing.T, reg *registry.Registry, id, querido string, cond func(session.Session) bool) {
	t.Helper()

	sub := reg.Subscribe()
	defer reg.Unsubscribe(sub)

	if s, ok := reg.Get(id); ok && cond(s) {
		return
	}

	for {
		select {
		case s, ok := <-sub.C:
			if !ok {
				// Só fecha por Unsubscribe, que só o defer acima chama — não
				// deveria disparar enquanto este loop roda.
				t.Fatalf("sessão %q: canal de eventos do registry fechou antes de %s", id, querido)
			}
			if s.ID == id && cond(s) {
				return
			}
		case <-ctx.Done():
			got, _ := reg.Get(id)
			t.Fatalf("sessão %q não alcançou %s dentro do teto de segurança (estado atual %q, pending %q)",
				id, querido, got.State, got.PendingPrompt)
		}
	}
}

// safetyDeadline devolve o teto de segurança ÚNICO deste teste — tanto do ctx
// (conexão WS e seção 5) quanto das esperas por evento: t.Deadline() (o
// -timeout do binário de teste) com 2s de margem para reportar a falha REAL
// antes de o arcabouco matar o processo primeiro (aí o teste apareceria como
// "timeout", escondendo qual estado faltou). Sem -timeout que aperte isso (o
// padrão do `go test` é 10min), cai num teto pragmático de 20s: generoso o
// bastante para não confundir carga com defeito, mas curto o bastante para não
// deixar um bug real prender a suíte por minutos. Este número não é "critério
// de aprovação sob carga" (esse critério agora é o evento do Subscribe) — é só
// "não trave para sempre num bug real".
func safetyDeadline(t *testing.T) time.Time {
	t.Helper()
	const tetoPragmatico = 20 * time.Second
	if dl, ok := t.Deadline(); ok {
		if margem := time.Until(dl) - 2*time.Second; margem < tetoPragmatico {
			if margem <= 0 {
				return time.Now()
			}
			return dl.Add(-2 * time.Second)
		}
	}
	return time.Now().Add(tetoPragmatico)
}
