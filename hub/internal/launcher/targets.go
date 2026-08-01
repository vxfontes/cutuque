package launcher

import (
	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/adapter/codex"
	"github.com/vxfontes/cutuque/hub/internal/adapter/opencode"
	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// TargetsFor monta os alvos ssh de uma máquina — um por agente, indexados por
// Kind() como o Launcher espera. Serve para os dois caminhos: o boot com as
// máquinas do CUTUQUE_SSH_TARGETS e o cadastro em runtime pela aba Máquinas.
//
// knownHosts é o known_hosts próprio do Cutuque (vazio quando o cadastro pelo
// app está desligado). A identidade só é amarrada quando a máquina tem chave
// gerada pelo hub E existe known_hosts: máquina do hub.env continua conectando
// pelo ~/.ssh do container, exatamente como antes.
func TargetsFor(m machine.Machine, knownHosts string) map[string]claudecode.Target {
	cc := claudecode.NewSSHTarget(m.Name, m.Dest)
	// Caminho absoluto do claude remoto (3º campo do CUTUQUE_SSH_TARGETS):
	// necessário quando o binário certo não é o primeiro no PATH do login shell
	// remoto. Vazio → default.
	cc.SetRemoteClaudeCmd(m.RemoteCmd)
	cx := codex.NewSSHTarget(m.Name, m.Dest)
	oc := opencode.NewSSHTarget(m.Name, m.Dest)

	cc.SetIdentity(m.KeyPath, knownHosts, m.Port)
	cx.SetIdentity(m.KeyPath, knownHosts, m.Port)
	oc.SetIdentity(m.KeyPath, knownHosts, m.Port)

	return map[string]claudecode.Target{
		cc.Kind(): cc,
		cx.Kind(): cx,
		oc.Kind(): oc,
	}
}

// snapshot devolve o mapa de alvos vigente. As mutações substituem o mapa
// inteiro, então o que sai daqui nunca muda debaixo de quem está lendo — só
// não pode ser escrito.
func (l *Launcher) snapshot() map[string]map[string]claudecode.Target {
	l.targetsMu.RLock()
	defer l.targetsMu.RUnlock()
	return l.targets
}

// SetMachineKnownHosts fixa o known_hosts usado pelas máquinas cadastradas no
// app. Chamado uma vez no boot, antes de servir: não retroage sobre alvos já
// montados.
func (l *Launcher) SetMachineKnownHosts(path string) {
	l.targetsMu.Lock()
	l.machineKnownHosts = path
	l.targetsMu.Unlock()
}

// RegisterMachine faz a máquina virar alvo de verdade — é o que separa um
// cadastro na lista de uma máquina onde dá para lançar sessão e abrir arquivo.
// Idempotente: cadastrar de novo (ou depois de um PATCH de destino) troca os
// alvos pelos novos.
func (l *Launcher) RegisterMachine(m machine.Machine) {
	l.targetsMu.Lock()
	defer l.targetsMu.Unlock()
	next := cloneTargets(l.targets)
	next[m.Name] = TargetsFor(m, l.machineKnownHosts)
	l.targets = next
}

// UnregisterMachine tira a máquina do mapa de alvos. Sessões já vivas nela
// seguem com o handle que já têm — quem perde é só o próximo lançamento, que
// passa a bater em ErrUnknownMachine.
func (l *Launcher) UnregisterMachine(name string) {
	l.targetsMu.Lock()
	defer l.targetsMu.Unlock()
	if _, ok := l.targets[name]; !ok {
		return
	}
	next := cloneTargets(l.targets)
	delete(next, name)
	l.targets = next
}

// cloneTargets copia o nível de fora do mapa. O de dentro (agente → alvo) é
// substituído inteiro pelo RegisterMachine, nunca editado, então compartilhá-lo
// entre a cópia e o original é seguro.
func cloneTargets(cur map[string]map[string]claudecode.Target) map[string]map[string]claudecode.Target {
	next := make(map[string]map[string]claudecode.Target, len(cur)+1)
	for name, byAgent := range cur {
		next[name] = byAgent
	}
	return next
}
