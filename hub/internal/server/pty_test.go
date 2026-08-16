package server

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
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

// MARK: - O shell sobrevive à conexão? (card 2a1ee8d8193cb9df)

// shellQueAvisaOPid roda `sh` gravando o próprio pid em `arquivo` antes de
// virar o processo de longa vida. É o stand-in do `ssh -tt`: o número no
// arquivo é o pid do processo que SOBRA se a limpeza falhar.
//
// `exec` no fim não é enfeite — sem ele o pid gravado seria o do `sh`, que
// morreria de qualquer jeito ao fim do script, e o teste passaria sem provar
// nada sobre o processo que interessa.
func shellQueAvisaOPid(arquivo string) *fakeLauncher {
	return &fakeLauncher{shellProg: "sh", shellArgs: []string{"-c",
		"echo $$ > " + arquivo + "; exec sleep 300"}}
}

// pidGravado espera o shell fake dizer quem ele é. Sem isto o teste correria
// contra o `fork`/`exec` e leria arquivo vazio.
func pidGravado(t *testing.T, arquivo string) int {
	t.Helper()
	limite := time.Now().Add(5 * time.Second)
	for time.Now().Before(limite) {
		if b, err := os.ReadFile(arquivo); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("o shell fake não gravou o pid em %s", arquivo)
	return 0
}

// vivo pergunta ao kernel se o pid ainda existe. `signal 0` não entrega sinal
// nenhum, só valida o destino.
//
// ATENÇÃO ao que isto significa aqui: o shell fake é filho DIRETO do processo de
// teste, então enquanto ninguém colher o `Wait` ele fica zumbi — e zumbi aceita
// o sinal 0. Ou seja: `!vivo(pid)` prova as duas metades da limpeza juntas,
// morto E colhido, que é exatamente o que o `encerraShell` promete.
func vivo(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

// esperaMorrer devolve quanto tempo o processo levou para sumir, ou falha o
// teste no prazo — é a MEDIÇÃO que o card pede, não só a asserção.
func esperaMorrer(t *testing.T, pid int, prazo time.Duration) time.Duration {
	t.Helper()
	inicio := time.Now()
	limite := inicio.Add(prazo)
	for time.Now().Before(limite) {
		if !vivo(pid) {
			return time.Since(inicio)
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("o shell (pid %d) seguia vivo depois de %s — é o vazamento do card 2a1ee8d8193cb9df. ps: %s",
		pid, prazo, estadoDoProcesso(pid))
	return 0
}

// estadoDoProcesso é só para a mensagem de falha, e ganha o teste inteiro: "Z"
// (zumbi) significa processo MORTO e não colhido — problema de `Wait` — enquanto
// "S"/"R" significa `ssh` de pé de verdade, segurando a sessão do outro lado.
// Sem esta linha as duas falham igual e a investigação começa do zero.
func estadoDoProcesso(pid int) string {
	out, err := exec.Command("ps", "-o", "stat=,command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "(ps falhou: " + err.Error() + ")"
	}
	return strings.TrimSpace(string(out))
}

// Cliente que vai embora SEM close frame (o `kill -9` no cliente da repro
// mínima do card): o `CloseNow` fecha o TCP na cara do hub, sem handshake.
//
// [13/08/2026] Este teste nasceu porque o doc do `PTYHandler` afirma "fechou o
// socket, o `ssh` morre junto" e havia evidência de produção do contrário —
// cinco `ssh -tt` vivos dentro do container depois de cinco sessões de teste.
// A cadeia que precisa rodar é `Read` falha → `close(clienteCaiu)` → `f.Close()`
// → `bombeiaSaida` retorna → `encerraShell`.
func TestPTYQuedaAbruptaDoClienteMataOShell(t *testing.T) {
	arquivo := filepath.Join(t.TempDir(), "pid")
	c, _ := abrePTY(t, shellQueAvisaOPid(arquivo))
	pid := pidGravado(t, arquivo)

	c.CloseNow() // sem close frame, de propósito

	t.Logf("shell morto e colhido em %s depois da queda abrupta", esperaMorrer(t, pid, 10*time.Second))
}

// Cliente que fecha LIMPO (código 1000). Está aqui porque a segunda evidência
// do card corrigiu a premissa da primeira: ela fechou o socket direito e vazou
// igual, então o fechamento limpo precisa de asserção própria — não é o caminho
// "sem problema" que o nome do card sugeria.
func TestPTYFechamentoLimpoTambemMataOShell(t *testing.T) {
	arquivo := filepath.Join(t.TempDir(), "pid")
	c, _ := abrePTY(t, shellQueAvisaOPid(arquivo))
	pid := pidGravado(t, arquivo)

	if err := c.Close(websocket.StatusNormalClosure, ""); err != nil {
		t.Fatalf("Close: %v", err)
	}

	t.Logf("shell morto e colhido em %s depois do fechamento limpo", esperaMorrer(t, pid, 10*time.Second))
}

// Hipótese 2 do card: o shell IGNORA o SIGHUP que fechar o PTY manda. É para
// isso que existe o `ptyKillGrace` — passado o prazo, vem o `Kill`. Sem esta
// prova, o `select` com `time.After` no `encerraShell` é fé.
func TestPTYShellQueIgnoraSIGHUPMorreNoKill(t *testing.T) {
	arquivo := filepath.Join(t.TempDir(), "pid")
	// Sem `exec` aqui de propósito: o `trap` tem de sobreviver, e é o próprio
	// `sh` que precisa ficar vivo ignorando o sinal.
	c, _ := abrePTY(t, &fakeLauncher{shellProg: "sh", shellArgs: []string{"-c",
		"trap '' HUP; echo $$ > " + arquivo + "; while :; do sleep 1; done"}})
	pid := pidGravado(t, arquivo)

	c.CloseNow()

	levou := esperaMorrer(t, pid, 4*ptyKillGrace)
	if levou < ptyKillGrace {
		t.Errorf("morreu em %s, antes do prazo de %s — o SIGHUP pegou, então este teste não está mais provando o Kill", levou, ptyKillGrace)
	}
	t.Logf("shell surdo a SIGHUP morto em %s (ptyKillGrace = %s)", levou, ptyKillGrace)
}

// O caso que o `vigiaCliente` existe para pegar, e que nenhum teste cobria: o
// celular que dormiu ou trocou de rede. O socket do hub segue ABERTO, o `Read`
// fica pendurado para sempre, e a ÚNICA coisa que pode perceber é o ping sem
// pong. Prova as duas metades: com o cliente vivo, vários pings passam e nada é
// derrubado; congelado, o shell morre.
func TestPTYClienteCongeladoCaiNoPingSemPong(t *testing.T) {
	// [16/08/2026] Isto reatribuía as duas globais de ping/escrita do
	// WebSocket (save/overwrite/defer-restore) para encurtar o teste. Corria
	// com a goroutine de produção que lê essas mesmas variáveis —
	// httptest.Server.Close() não espera a goroutine "hijacked" terminar,
	// então não há happens-before entre o defer-restore e a leitura em
	// produção. `go test -race` pegava a race de verdade. Agora os prazos
	// curtos vão por injeção (WithWSTimeouts), sem tocar em global nenhuma.
	ping, escrita := 50*time.Millisecond, 300*time.Millisecond

	arquivo := filepath.Join(t.TempDir(), "pid")
	cfg, reg := testDeps()
	srv := httptest.NewServer(Router(cfg, reg, shellQueAvisaOPid(arquivo), WithWSTimeouts(ping, escrita)))
	defer srv.Close()

	endereco, congelar := proxyCongelavel(t, strings.TrimPrefix(srv.URL, "http://"))

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws://"+endereco+"/machines/vps/pty?token=secret&cols=100&rows=40", nil)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer c.CloseNow()

	// O coder/websocket só responde ping DENTRO de um Read — sem esta goroutine
	// o teste passaria por motivo errado (nenhum pong chega nem com o cliente
	// saudável, e não haveria o que congelar).
	go func() {
		for {
			if _, _, err := c.Read(ctx); err != nil {
				return
			}
		}
	}()

	pid := pidGravado(t, arquivo)
	time.Sleep(6 * ping)
	if !vivo(pid) {
		t.Fatalf("o shell morreu com o cliente SAUDÁVEL — o ping está derrubando conexão boa")
	}

	congelar()
	t.Logf("shell morto e colhido em %s depois de o cliente congelar (ping %s, prazo do pong %s)",
		esperaMorrer(t, pid, 20*time.Second), ping, escrita)
}

// proxyCongelavel é um proxy TCP que, ao congelar, PARA de repassar bytes sem
// fechar nada — é o celular que dormiu: as duas pontas seguem com socket aberto
// e o hub não recebe FIN nenhum para o `Read` notar.
func proxyCongelavel(t *testing.T, destino string) (endereco string, congelar func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	parado := make(chan struct{})
	go func() {
		conexao, err := ln.Accept()
		if err != nil {
			return
		}
		acima, err := net.Dial("tcp", destino)
		if err != nil {
			conexao.Close()
			return
		}
		t.Cleanup(func() { conexao.Close(); acima.Close() })

		copia := func(dst, src net.Conn) {
			buf := make([]byte, 32*1024)
			for {
				n, err := src.Read(buf)
				select {
				case <-parado:
					return // congelado: engole o que leu e não fecha nada
				default:
				}
				if n > 0 {
					if _, werr := dst.Write(buf[:n]); werr != nil {
						return
					}
				}
				if err != nil {
					return
				}
			}
		}
		go copia(acima, conexao)
		go copia(conexao, acima)
	}()
	return ln.Addr().String(), func() { close(parado) }
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
