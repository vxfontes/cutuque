package claudecode

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vxfontes/cutuque/hub/internal/session"
)

// TestSSHLiveBuildsCommand: SSHTarget.Live monta o comando ssh e parseia a saída
// no mesmo shape do discover — troca o `ssh` por um fake que ecoa uma fixture.
func TestSSHLiveBuildsCommand(t *testing.T) {
	dir := t.TempDir()
	fakeSSH := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ncat > /dev/null\n" +
		`printf '%s' '[{"id":"live-1","cwd":"/r","title":"rodando","last":"oi","count":3,"modified":9}]'` + "\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o755); err != nil {
		t.Fatalf("fake ssh: %v", err)
	}
	tgt := newSSHCommand("macmini", "dest", defaultRemoteClaudeCmd, fakeSSH, sshClaudeArgs)

	got, err := tgt.Live(context.Background())
	if err != nil {
		t.Fatalf("Live: %v", err)
	}
	if len(got) != 1 || got[0].ID != "live-1" || got[0].Cwd != "/r" {
		t.Fatalf("got = %+v, quero [live-1]", got)
	}
}

// liveHome monta um HOME falso com um transcript por sid na pasta de projeto
// dada. O primeiro sid é o mais recente e cada seguinte fica 1 min mais velho —
// ainda bem dentro da janela de 900s, então a poda por recência não interfere e
// os testes controlam a ORDEM sem depender do relógio do disco.
func liveHome(t *testing.T, projDir, cwd string, sids ...string) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", projDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	now := time.Now()
	for i, sid := range sids {
		line := `{"type":"user","cwd":"` + cwd + `","message":{"content":"arrumar o hub"}}` + "\n"
		f := filepath.Join(dir, sid+".jsonl")
		if err := os.WriteFile(f, []byte(line), 0o644); err != nil {
			t.Fatalf("transcript %s: %v", sid, err)
		}
		mt := now.Add(-time.Duration(i) * time.Minute)
		if err := os.Chtimes(f, mt, mt); err != nil {
			t.Fatalf("chtimes %s: %v", sid, err)
		}
	}
	return home
}

// runLive roda o liveScript de verdade sobre um HOME falso e um PATH com
// `ps`/`lsof` falsos. Devolve o erro em vez de abortar: distinguir "não achou
// nada" de "o oráculo quebrou" é justamente o que alguns testes verificam.
func runLive(t *testing.T, home, psBody, lsofCwd string) ([]session.Discovered, error) {
	t.Helper()
	return runLiveFakes(t, home, map[string]string{
		"ps":   psBody,
		"lsof": "#!/bin/sh\nprintf 'n%s\\n' " + shQuote(lsofCwd) + "\n",
	})
}

// runLiveFakes é o runLive sem opinião sobre os fakes: quem chama entrega o
// corpo de cada binário. Só os testes que precisam de um `lsof` fora do comum
// (travado, sumido) usam esta forma.
func runLiveFakes(t *testing.T, home string, fakes map[string]string) ([]session.Discovered, error) {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando")
	}
	bin := t.TempDir()
	for name, body := range fakes {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatalf("fake %s: %v", name, err)
		}
	}

	cmd := exec.Command(py, "-")
	cmd.Env = append(os.Environ(), "HOME="+home, "PATH="+bin+":"+os.Getenv("PATH"))
	cmd.Stdin = strings.NewReader(liveScript)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	got, err := parseDiscovered(out)
	if err != nil {
		t.Fatalf("parse: %v (out=%q)", err, out)
	}
	return got, nil
}

// liveFixture é o caso de um processo só: exercita a detecção real (encoding de
// caminho, argv, janela) sem depender dos processos de quem roda o teste.
func liveFixture(t *testing.T, projDir, sid, psLine, lsofCwd string) []session.Discovered {
	t.Helper()
	home := liveHome(t, projDir, lsofCwd, sid)
	got, err := runLive(t, home, "#!/bin/sh\nprintf '%s\\n' "+shQuote(psLine)+"\n", lsofCwd)
	if err != nil {
		t.Fatalf("liveScript falhou: %v", err)
	}
	return got
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// TestLiveScriptFindsSessionInDottedCwd cobre o bug do oráculo: o Claude Code
// troca TODO caractere fora de [A-Za-z0-9-] por '-' no nome da pasta de
// transcript, e o script trocava só '/'. Resultado: toda sessão de agente
// (.maestri/roles/<uuid>) era invisível em GET /machines/{m}/live.
func TestLiveScriptFindsSessionInDottedCwd(t *testing.T) {
	const (
		cwd  = "/Users/x/coding/personal/.maestri/roles/role_1"
		enc  = "-Users-x-coding-personal--maestri-roles-role-1"
		sid  = "11111111-2222-3333-4444-555555555555"
		proc = "12345 claude"
	)
	got := liveFixture(t, enc, sid, proc, cwd)
	if len(got) != 1 || got[0].ID != sid {
		t.Fatalf("got = %+v, quero a sessão %s viva (regra de encoding errada?)", got, sid)
	}
	if got[0].Cwd != cwd {
		t.Errorf("Cwd = %q, quero %q", got[0].Cwd, cwd)
	}
}

// TestLiveScriptFindsSessionByResumeFlag: o hub SEMPRE relança com --resume
// (target.go), e sid_from_cmd só olhava --session-id — então toda sessão
// relançada pelo hub caía no fallback por cwd, que é o caminho frágil.
func TestLiveScriptFindsSessionByResumeFlag(t *testing.T) {
	const sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	// Pasta com nome que NÃO corresponde ao cwd: se o script achar a sessão,
	// foi pelo argv, não pelo mapeamento de diretório.
	got := liveFixture(t, "pasta-qualquer", sid, "999 claude --resume "+sid, "/tmp/outro")
	if len(got) != 1 || got[0].ID != sid {
		t.Fatalf("got = %+v, quero a sessão %s achada via --resume", got, sid)
	}
}

// TestLiveScriptSeesEveryProcessInTheSameCwd cobre o colapso de sessões: dois
// `claude` sem flag de id na MESMA pasta resolviam os dois para o .jsonl de
// mtime máximo, então uma delas ficava invisível no oráculo. Enquanto o Live só
// alimentava o sheet de descoberta isso era cosmético; com o reaper consumindo
// o mesmo mapa, a sessão invisível vira "não está viva" e é derrubada de
// running em pleno uso. É exatamente o caso da usuária (três sessões com cwd e
// pane idênticos no hub de produção).
func TestLiveScriptSeesEveryProcessInTheSameCwd(t *testing.T) {
	const (
		cwd   = "/Users/x/coding/personal"
		enc   = "-Users-x-coding-personal"
		nova  = "aaaaaaaa-1111-2222-3333-444444444444"
		velha = "bbbbbbbb-1111-2222-3333-444444444444"
	)
	home := liveHome(t, enc, cwd, nova, velha)

	got, err := runLive(t, home, "#!/bin/sh\nprintf '%s\\n' '111 claude' '222 claude'\n", cwd)
	if err != nil {
		t.Fatalf("liveScript: %v", err)
	}
	ids := make(map[string]bool, len(got))
	for _, d := range got {
		ids[d.ID] = true
	}
	if !ids[nova] || !ids[velha] {
		t.Fatalf("ids = %v, quero as DUAS sessões vivas (%s e %s)", ids, nova, velha)
	}

	// O outro lado da moeda: com um processo só, continua sendo uma. Admitir os
	// N mais recentes não pode virar licença para inventar sessão viva.
	um, err := runLive(t, home, "#!/bin/sh\nprintf '%s\\n' '111 claude'\n", cwd)
	if err != nil {
		t.Fatalf("liveScript (1 processo): %v", err)
	}
	if len(um) != 1 || um[0].ID != nova {
		t.Fatalf("got = %+v, quero só a mais recente (%s)", um, nova)
	}
}

// TestLiveScriptFailsWhenPsFails: `ps` quebrado tem que virar ERRO, não lista
// vazia. Uma lista vazia sai daqui indistinguível de "nenhuma sessão viva nesta
// máquina" — e o reaper leria isso como veredito e ceifaria todas as sessões
// running da máquina de uma vez. Se este teste cair, "não sei" voltou a
// significar "morreu".
func TestLiveScriptFailsWhenPsFails(t *testing.T) {
	const sid = "cccccccc-1111-2222-3333-444444444444"
	home := liveHome(t, "-tmp-x", "/tmp/x", sid)

	got, err := runLive(t, home, "#!/bin/sh\necho 'ps: falhou' >&2\nexit 1\n", "/tmp/x")
	if err == nil {
		t.Fatalf("liveScript devolveu %+v sem erro; quero falha (ps quebrado ≠ máquina sem sessões)", got)
	}
}

// TestLiveScriptFailsWhenLsofHangs: mesma regra do `ps`, um andar abaixo. O
// `lsof` só é consultado para processo SEM --session-id no argv — justo a
// sessão que não tem nenhuma outra evidência. Se o timeout virasse cwd vazio, o
// processo sumia da varredura, o reaper via a sessão faltando e a ceifava: uma
// máquina carregada derrubaria sessões vivas. Tem que sair como erro.
func TestLiveScriptFailsWhenLsofHangs(t *testing.T) {
	const sid = "dddddddd-1111-2222-3333-444444444444"
	home := liveHome(t, "-tmp-y", "/tmp/y", sid)

	got, err := runLiveFakes(t, home, map[string]string{
		"ps":   "#!/bin/sh\necho '4242 claude'\n",
		"lsof": "#!/bin/sh\nsleep 30\n",
	})
	if err == nil {
		t.Fatalf("liveScript devolveu %+v sem erro; quero falha (lsof travado ≠ processo sem cwd)", got)
	}
}

// TestLiveScriptSkipsOnlyTheDeadPid: o outro lado da moeda. `lsof` que roda e
// não acha o pid (ele saiu entre o ps e o lsof — corrida normal) é conhecimento,
// não ignorância: derruba só aquele pid e a varredura segue.
func TestLiveScriptSkipsOnlyTheDeadPid(t *testing.T) {
	const sid = "eeeeeeee-1111-2222-3333-444444444444"
	home := liveHome(t, "-tmp-z", "/tmp/z", sid)

	got, err := runLiveFakes(t, home, map[string]string{
		"ps":   "#!/bin/sh\necho '4242 claude'\n",
		"lsof": "#!/bin/sh\nexit 1\n",
	})
	if err != nil {
		t.Fatalf("liveScript falhou: %v; pid que sumiu não é motivo para derrubar a máquina", err)
	}
	if len(got) != 0 {
		t.Fatalf("got = %+v, quero lista vazia (o único processo já tinha saído)", got)
	}
}

// TestLiveScriptRunsAndEmitsJSON garante que o liveScript é python válido e
// sempre emite uma lista JSON (mesmo sem sessões vivas), sobre um HOME vazio —
// não valida a detecção de processos (depende do SO), só o contrato de saída.
func TestLiveScriptRunsAndEmitsJSON(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 ausente; pulando")
	}
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".claude", "projects"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	cmd := exec.Command(py, "-")
	cmd.Env = append(os.Environ(), "HOME="+home)
	cmd.Stdin = strings.NewReader(liveScript)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("liveScript falhou: %v", err)
	}
	var list []map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(out))), &list); err != nil {
		t.Fatalf("liveScript não emitiu JSON de lista: %v (out=%q)", err, out)
	}
}
