package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/creack/pty"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
)

// Limites do terminal livre.
var (
	// ptyReadLimit é o teto de uma mensagem vinda do app. Teclado manda bytes,
	// colar manda alguns KB; 64 KB é folgado e impede que um cliente maluco
	// faça o hub alocar sem teto.
	ptyReadLimit int64 = 64 * 1024
	// ptyChunk é o buffer de leitura do PTY. Uma tela de 200x60 com cores cabe
	// bem aqui, e o WebSocket manda o que veio sem esperar encher.
	ptyChunk = 32 * 1024
	// ptyKillGrace é quanto se espera o `ssh` sair sozinho depois que a
	// conexão morre, antes de matá-lo. Sem isso um app que fecha o app deixaria
	// um ssh vivo por conexão.
	ptyKillGrace = 2 * time.Second
)

// Tamanho de terminal aceito. O piso evita divisão por zero do outro lado; o
// teto evita alocar uma tela absurda por causa de um query param mentiroso.
const (
	ptyMinCols, ptyMinRows = 20, 4
	ptyMaxCols, ptyMaxRows = 500, 300
	ptyDefCols, ptyDefRows = 80, 24
)

// ptyControl é a mensagem de controle do app (frame de TEXTO). O teclado em si
// vai em frames BINÁRIOS — o tipo do frame é o que separa "digitei isso" de
// "a tela mudou de tamanho", sem precisar de escape nem prefixo nos bytes.
type ptyControl struct {
	Type string `json:"type"` // "resize"
	Cols int    `json:"cols"`
	Rows int    `json:"rows"`
}

// ptyEvent é o que o hub manda de volta em frame de TEXTO. A saída do terminal
// vai em frames binários; texto é sempre metadado.
type ptyEvent struct {
	Type    string `json:"type"`              // "exit" | "error"
	Code    int    `json:"code,omitempty"`    // só em "exit"
	Message string `json:"message,omitempty"` // só em "error"
}

// PTYHandler abre um shell interativo na máquina e faz proxy dos bytes entre o
// PTY e o WebSocket — o terminal livre da aba Máquinas.
//
// A sessão é efêmera de propósito: fechou o socket, o `ssh` morre junto. Não há
// tmux no meio (ver "Fora de escopo" do spec) — persistir sessão é outro
// modelo, e misturar os dois no mesmo painel confunde mais do que ajuda.
//
// Por que um PTY local, se o `-tt` já pede um PTY do outro lado: sem tty no
// stdin daqui, o `ssh` não tem para onde ouvir SIGWINCH e o redimensionar nunca
// chegaria ao remoto. Com o PTY local, o resize vira TIOCSWINSZ → SIGWINCH →
// window-change no protocolo ssh, que é o caminho de verdade.
//
//	GET /machines/{machine}/pty?cols=&rows=  (WebSocket)
//	→ binário: bytes do terminal, nos dois sentidos
//	→ texto (app→hub):  {"type":"resize","cols","rows"}
//	→ texto (hub→app):  {"type":"exit","code"} | {"type":"error","message"}
func PTYHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// O comando é montado ANTES do upgrade: máquina desconhecida tem que
		// virar 404 de HTTP mesmo, não um WebSocket que abre e fecha na cara.
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()

		cmd, err := lch.ShellCommand(ctx, r.PathValue("machine"))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
			return
		case errors.Is(err, launcher.ErrNoShell):
			writeJSONError(w, http.StatusNotImplemented, "no_shell")
			return
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "pty_failed")
			return
		}

		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return // Accept já respondeu o erro de handshake
		}
		defer c.CloseNow()
		c.SetReadLimit(ptyReadLimit)

		cols, rows := ptySize(r.URL.Query().Get("cols"), r.URL.Query().Get("rows"))
		f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
		if err != nil {
			// O ssh nem subiu (binário sumido, sem pty no container): a causa
			// vai por extenso, é o único jeito de a usuária saber o que houve.
			_ = writeJSON(ctx, c, ptyEvent{Type: "error", Message: err.Error()})
			_ = c.Close(websocket.StatusInternalError, "pty")
			return
		}

		// Quem morre primeiro decide o resto, e as duas pontas precisam saber
		// disso — daí os dois canais.
		saidaAcabou := make(chan struct{})
		clienteCaiu := make(chan struct{})

		vigiaCliente(ctx, c)

		// PTY → WebSocket. Esta goroutine é a DONA do processo depois que a
		// saída acaba: ela encerra e ela relata. Um Wait só no Cmd — dois
		// concorrentes é corrida de verdade.
		go func() {
			defer close(saidaAcabou)
			bombeiaSaida(ctx, c, f)
			code := encerraShell(cmd, f)
			// "Você digitou exit" e "o host recusou a conexão" não podem chegar
			// iguais no app. Se quem caiu foi o cliente, não há a quem contar.
			select {
			case <-clienteCaiu:
			default:
				relataSaida(c, code)
			}
		}()

		// WebSocket → PTY. A leitura do socket fica na principal: Read não pode
		// ser concorrente. O ctx aqui NÃO é derrubado pela outra ponta — o
		// coder/websocket fecha a conexão quando o Read morre por cancelamento,
		// e aí o aviso de saída não teria por onde sair.
		for {
			typ, data, err := c.Read(ctx)
			if err != nil {
				break
			}
			if typ == websocket.MessageText {
				aplicaControle(f, data)
				continue
			}
			if _, err := f.Write(data); err != nil {
				break
			}
		}

		// Chegar aqui com o shell vivo significa que quem caiu foi o cliente. Até
		// 2026-08-13 esta parte dizia "fechar o PTY solta a goroutine, que
		// encerra o `ssh`" — era falso, e o `ssh` vazava por isso (card
		// 2a1ee8d8193cb9df). O sinal sai explícito no derrubaShell; quem fecha o
		// mestre e faz o Wait continua sendo a goroutine da saída.
		close(clienteCaiu)
		derrubaShell(cmd, saidaAcabou)
		<-saidaAcabou
	}
}

// vigiaCliente pinga o app de tempos em tempos e derruba a conexão quando ele
// para de responder. Sem isso, um celular que dormiu ou trocou de rede sem
// fechar o socket deixaria o Read pendurado e o `ssh` vivo para sempre.
func vigiaCliente(ctx context.Context, c *websocket.Conn) {
	go func() {
		tick := time.NewTicker(wsPingInterval)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				pctx, pcancel := context.WithTimeout(ctx, wsWriteTimeout)
				err := c.Ping(pctx)
				pcancel()
				if err != nil {
					// Fechar é o que solta o Read da goroutine principal.
					_ = c.CloseNow()
					return
				}
			}
		}
	}()
}

// bombeiaSaida joga tudo que o terminal produz no socket, sem esperar encher
// buffer: latência de eco é o que faz um terminal parecer vivo.
func bombeiaSaida(ctx context.Context, c *websocket.Conn, f io.Reader) {
	buf := make([]byte, ptyChunk)
	for {
		n, err := f.Read(buf)
		if n > 0 {
			wctx, wcancel := context.WithTimeout(ctx, wsWriteTimeout)
			werr := c.Write(wctx, websocket.MessageBinary, buf[:n])
			wcancel()
			if werr != nil {
				return
			}
		}
		if err != nil {
			// EOF/EIO aqui é o normal: é assim que o PTY avisa que o filho
			// saiu, no Linux e no macOS.
			return
		}
	}
}

// aplicaControle trata uma mensagem de texto do app. Hoje só existe o resize;
// mensagem que não entende é ignorada de propósito — um app mais novo falando
// com um hub mais velho não pode derrubar o terminal por causa disso.
func aplicaControle(f *os.File, data []byte) {
	var ctl ptyControl
	if err := json.Unmarshal(data, &ctl); err != nil || ctl.Type != "resize" {
		return
	}
	cols, rows := ptySize(strconv.Itoa(ctl.Cols), strconv.Itoa(ctl.Rows))
	_ = pty.Setsize(f, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

// ptySize valida o tamanho pedido. Valor ausente ou fora da faixa vira o
// padrão: o app manda o tamanho medido na tela, mas o query param é entrada de
// fora como qualquer outra.
func ptySize(colsRaw, rowsRaw string) (cols, rows int) {
	return dentroDaFaixa(colsRaw, ptyMinCols, ptyMaxCols, ptyDefCols),
		dentroDaFaixa(rowsRaw, ptyMinRows, ptyMaxRows, ptyDefRows)
}

func dentroDaFaixa(raw string, min, max, padrao int) int {
	n, err := strconv.Atoi(raw)
	if err != nil || n < min || n > max {
		return padrao
	}
	return n
}

// derrubaShell mata o shell quando quem foi embora foi o CLIENTE.
//
// Existe porque fechar o mestre do PTY NÃO derruba o shell — ao contrário do
// que este arquivo afirmou até 2026-08-13 (card 2a1ee8d8193cb9df). O `os.File`
// do mestre não é pollável pelo runtime do Go, então o `Close` não tem como
// desalojar um `Read` já pendurado: ele só marca o fd como fechado, o
// `close(2)` de verdade fica esperando o `Read` voltar, o `Read` espera o filho
// falar e o filho espera para sempre. Medido: `bombeiaSaida` nunca voltava,
// `encerraShell` nunca rodava, o handler dormia no `<-saidaAcabou`, o `cancel()`
// adiado nunca disparava e o `ssh` seguia vivo com PPID 1. Valia até para o
// fechamento limpo do socket, que era o mais confuso do sintoma.
//
// SIGHUP primeiro por dois motivos: é o sinal que o pendurar do tty deveria ter
// mandado, e o cliente ssh trata SIGHUP derrubando a conexão de forma ordenada
// — é o que dá chance de a sessão do sshd no destino ir embora junto, em vez de
// só o kernel resetar o TCP. SIGKILL fica para quem ignora o sinal.
//
// Ao GRUPO, e não ao processo: hangup de tty de verdade acorda o grupo de
// primeiro plano inteiro, e um neto segurando o escravo mantém o mestre sem EOF
// pelo mesmo motivo de sempre.
func derrubaShell(cmd *exec.Cmd, saidaAcabou <-chan struct{}) {
	select {
	case <-saidaAcabou:
		// O shell já acabou por conta própria (`exit`, host caiu): o Wait do
		// encerraShell já rodou, o pid pode ter sido reciclado e sinal nenhum
		// pode sair daqui.
		return
	default:
	}
	sinaliza(cmd.Process, syscall.SIGHUP)
	select {
	case <-saidaAcabou:
	case <-time.After(ptyKillGrace):
		sinaliza(cmd.Process, syscall.SIGKILL)
	}
}

// sinaliza manda o sinal ao grupo do processo, caindo no processo sozinho
// quando não dá.
//
// A checagem `pgid == pid` não é paranoia: ela confirma que o filho é o LÍDER
// do próprio grupo (o pty.Start pede Setsid). Sem ela, um filho que tivesse
// herdado o grupo do hub faria o hub matar a si mesmo.
func sinaliza(p *os.Process, sig syscall.Signal) {
	if pgid, err := syscall.Getpgid(p.Pid); err == nil && pgid == p.Pid {
		if syscall.Kill(-pgid, sig) == nil {
			return
		}
	}
	_ = p.Signal(sig)
}

// encerraShell fecha o mestre, espera o `ssh` sair e devolve com que código ele
// saiu. O Close aqui é o que solta o fd de verdade: o `Read` já voltou (é o que
// trouxe a goroutine da saída até esta linha), então não há mais ninguém
// pendurado para adiar o `close(2)` — ver derrubaShell para o que acontecia
// quando se fechava com um Read pendurado. O kill continua como rede: "a saída
// acabou" não é prova de que o processo morreu.
func encerraShell(cmd *exec.Cmd, f io.Closer) int {
	_ = f.Close()
	saiu := make(chan struct{})
	go func() { _ = cmd.Wait(); close(saiu) }()
	select {
	case <-saiu:
	case <-time.After(ptyKillGrace):
		_ = cmd.Process.Kill()
		<-saiu
	}
	return cmd.ProcessState.ExitCode()
}

// relataSaida conta ao app por que o terminal acabou, antes de fechar. Sem
// isso, sair com `exit` e cair a rede chegariam iguais: socket fechado.
func relataSaida(c *websocket.Conn, code int) {
	// Contexto próprio: o da conexão já morreu junto com o shell, e é
	// justamente depois dele que esta mensagem precisa sair.
	ctx, cancel := context.WithTimeout(context.Background(), wsWriteTimeout)
	defer cancel()
	_ = writeJSON(ctx, c, ptyEvent{Type: "exit", Code: code})
	_ = c.Close(websocket.StatusNormalClosure, "")
}
