package codex

import (
	"slices"
	"strings"
	"testing"
)

// Máquina cadastrada pela aba Máquinas conecta com a chave que o hub gerou e o
// known_hosts próprio. O codex precisa disto tanto quanto o claude-code: uma
// máquina do app onde só um dos agentes funciona é pior que nenhuma.
func TestIdentidadeDaMaquinaEntraNasOpcoesDeSsh(t *testing.T) {
	tgt := NewSSHTarget("vps", "vx@192.0.2.50")
	tgt.SetIdentity("/data/machines/keys/vps", "/data/machines/known_hosts", 2222)

	args := tgt.sshOpts()
	for _, quero := range []string{
		"/data/machines/keys/vps",
		"IdentitiesOnly=yes",
		"UserKnownHostsFile=/data/machines/known_hosts",
		"StrictHostKeyChecking=yes",
		"2222",
	} {
		if !slices.Contains(args, quero) {
			t.Errorf("faltou %q nos args: %v", quero, args)
		}
	}
	// O ssh honra a PRIMEIRA ocorrência: se o accept-new do base viesse antes,
	// a checagem estrita seria descartada sem barulho nenhum.
	if primeiroStrict(args) != "StrictHostKeyChecking=yes" {
		t.Errorf("o accept-new venceu a checagem estrita: %v", args)
	}
}

// Máquina do hub.env segue como antes: sem -i e com o accept-new de sempre.
func TestMaquinaDoEnvNaoGanhaIdentidade(t *testing.T) {
	tgt := NewSSHTarget("macmini", "macmini")
	args := tgt.sshOpts()
	if slices.Contains(args, "-i") || slices.Contains(args, "IdentitiesOnly=yes") {
		t.Errorf("máquina do env ganhou identidade que não é dela: %v", args)
	}
	if primeiroStrict(args) != "StrictHostKeyChecking=accept-new" {
		t.Errorf("o comportamento da máquina do env mudou: %v", args)
	}
}

func primeiroStrict(args []string) string {
	for _, a := range args {
		if strings.HasPrefix(a, "StrictHostKeyChecking=") {
			return a
		}
	}
	return ""
}
