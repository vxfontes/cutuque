package main

import (
	"io"
	"log/slog"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
)

// silentLogger descarta os logs (o teste só quer o valor de retorno, não
// afirmar sobre o texto do log de aviso).
func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// TestParseSSHTargetsEmptyYieldsEmptyMap cobre o caso "sem env var": nenhum
// alvo SSH declarado.
func TestParseSSHTargetsEmptyYieldsEmptyMap(t *testing.T) {
	got := parseSSHTargets("", silentLogger())
	if len(got) != 0 {
		t.Errorf("parseSSHTargets(\"\") = %v, quero mapa vazio", got)
	}
}

// TestParseSSHTargetsParsesValidEntries cobre o formato documentado:
// "nome=destino,nome2=destino2".
func TestParseSSHTargetsParsesValidEntries(t *testing.T) {
	got := parseSSHTargets("macbook=user@192.0.2.20,macmini=remote-host", silentLogger())
	want := map[string]string{
		"macbook": "user@192.0.2.20",
		"macmini": "remote-host",
	}
	if len(got) != len(want) {
		t.Fatalf("parseSSHTargets = %v, quero %v", got, want)
	}
	for k, v := range want {
		if got[k].dest != v {
			t.Errorf("parseSSHTargets[%q].dest = %q, quero %q", k, got[k].dest, v)
		}
	}
}

// TestParseSSHTargetsThirdFieldIsRemoteCmd cobre o formato "nome=dest=claudecmd":
// o 3º campo vira o caminho absoluto do claude remoto.
func TestParseSSHTargetsThirdFieldIsRemoteCmd(t *testing.T) {
	got := parseSSHTargets("macbook=example@192.0.2.20=/Users/example/.local/bin/claude", silentLogger())
	d, ok := got["macbook"]
	if !ok {
		t.Fatalf("parseSSHTargets = %v, quero a chave macbook", got)
	}
	if d.dest != "example@192.0.2.20" {
		t.Errorf("dest = %q", d.dest)
	}
	if d.remoteCmd != "/Users/example/.local/bin/claude" {
		t.Errorf("remoteCmd = %q, quero o caminho absoluto", d.remoteCmd)
	}
}

// TestParseSSHTargetsRejectsDashDest cobre a defesa contra injeção: um destino
// começando com "-" (ex.: -oProxyCommand=...) é ignorado.
func TestParseSSHTargetsRejectsDashDest(t *testing.T) {
	got := parseSSHTargets("evil=-oProxyCommand=touch /tmp/pwned,ok=user@host", silentLogger())
	if _, bad := got["evil"]; bad {
		t.Errorf("destino com '-' não deveria ser aceito: %v", got)
	}
	if got["ok"].dest != "user@host" {
		t.Errorf("entrada válida ao redor deveria sobreviver: %v", got)
	}
}

// TestParseSSHTargetsIgnoresMalformedEntries cobre o parse defensivo: entradas
// sem "=", com nome ou destino vazio são ignoradas — não derrubam o parse das
// entradas válidas ao redor.
func TestParseSSHTargetsIgnoresMalformedEntries(t *testing.T) {
	raw := "macbook=user@host, sem-igual , =destino-sem-nome, nome-sem-destino=, macmini=host2"
	got := parseSSHTargets(raw, silentLogger())
	want := map[string]string{
		"macbook": "user@host",
		"macmini": "host2",
	}
	if len(got) != len(want) {
		t.Fatalf("parseSSHTargets(%q) = %v, quero só as entradas válidas %v", raw, got, want)
	}
	for k, v := range want {
		if got[k].dest != v {
			t.Errorf("parseSSHTargets[%q].dest = %q, quero %q", k, got[k].dest, v)
		}
	}
}

// TestParseSSHTargetsTrimsWhitespace garante espaços ao redor de nome/destino
// não quebram o parse (formato amigável para copiar/colar em .env).
func TestParseSSHTargetsTrimsWhitespace(t *testing.T) {
	got := parseSSHTargets(" macbook = user@host , macmini = host2 ", silentLogger())
	if got["macbook"].dest != "user@host" || got["macmini"].dest != "host2" {
		t.Errorf("parseSSHTargets com espaços = %v", got)
	}
}

// TestBuildTargetsFallsBackToLocalMacbookWhenEmpty cobre a compatibilidade
// pedida na Fase 5: sem CUTUQUE_SSH_TARGETS, o comportamento é o de antes
// (LocalTarget "macbook").
func TestBuildTargetsFallsBackToLocalMacbookWhenEmpty(t *testing.T) {
	targets := buildTargets("", silentLogger())
	if len(targets) != 1 {
		t.Fatalf("targets = %v, quero só o macbook local", targets)
	}
	tgt, ok := targets["macbook"]
	if !ok {
		t.Fatalf("targets = %v, quero a chave \"macbook\"", targets)
	}
	if _, isLocal := tgt.(*claudecode.LocalTarget); !isLocal {
		t.Errorf("targets[\"macbook\"] = %T, quero *claudecode.LocalTarget", tgt)
	}
}

// TestBuildTargetsUsesSSHTargetsWhenConfigured cobre a Fase 5: com a env var
// setada, os alvos viram SSHTarget (hub numa máquina, claude noutra via ssh) —
// nenhum LocalTarget implícito é adicionado.
func TestBuildTargetsUsesSSHTargetsWhenConfigured(t *testing.T) {
	targets := buildTargets("macbook=user@192.0.2.20,macmini=remote-host", silentLogger())
	if len(targets) != 2 {
		t.Fatalf("targets = %v, quero 2 entradas", targets)
	}
	for _, name := range []string{"macbook", "macmini"} {
		tgt, ok := targets[name]
		if !ok {
			t.Fatalf("targets = %v, quero a chave %q", targets, name)
		}
		if _, isSSH := tgt.(*claudecode.SSHTarget); !isSSH {
			t.Errorf("targets[%q] = %T, quero *claudecode.SSHTarget", name, tgt)
		}
		if tgt.Name() != name {
			t.Errorf("targets[%q].Name() = %q", name, tgt.Name())
		}
	}
}
