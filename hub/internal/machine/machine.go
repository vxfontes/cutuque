// Package machine mantém o registro das máquinas SSH que o hub conhece: as que
// vêm do CUTUQUE_SSH_TARGETS (Source=env, imutáveis pelo app) e, a partir da
// F3, as cadastradas pelo app (Source=app). Nesta fase o registro é só de
// leitura e vive em memória — persistência nasce quando houver o que persistir.
package machine

import (
	"fmt"
	"strings"
	"sync"
)

// Source diz de onde a máquina veio. Máquina de env não é editável pelo app:
// quem manda nela é o hub.env.
type Source string

const (
	SourceEnv Source = "env"
	SourceApp Source = "app"
)

// defaultSSHPort é a porta usada quando a entrada não especifica outra.
const defaultSSHPort = 22

// Machine é uma máquina alcançável por ssh.
type Machine struct {
	Name string `json:"name"`
	Dest string `json:"dest"` // alias do ~/.ssh/config ou user@host
	Port int    `json:"port"`
	// RemoteCmd é o caminho do agente remoto (3º campo do CUTUQUE_SSH_TARGETS).
	// Vazio = default. Não é exposto ao app: é detalhe interno do hub.
	RemoteCmd string `json:"-"`
	Source    Source `json:"source"`
}

// ParseSSHTargets interpreta o CUTUQUE_SSH_TARGETS. Formato de cada entrada:
// "nome=destino" ou "nome=destino=comando-remoto", separadas por vírgula.
// destino = alias do ~/.ssh/config ou user@host.
//
// Parse defensivo: entrada malformada vira aviso e é ignorada — uma entrada
// ruim não pode impedir as demais nem derrubar o boot do hub. Devolve as
// máquinas na ordem em que aparecem e a lista de avisos.
func ParseSSHTargets(raw string) ([]Machine, []string) {
	var out []Machine
	var warns []string
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "=", 3)
		name := strings.TrimSpace(parts[0])
		dest := ""
		remoteCmd := ""
		if len(parts) >= 2 {
			dest = strings.TrimSpace(parts[1])
		}
		if len(parts) == 3 {
			remoteCmd = strings.TrimSpace(parts[2])
		}
		if name == "" || dest == "" {
			warns = append(warns, fmt.Sprintf("entrada malformada ignorada: %q", entry))
			continue
		}
		// Defesa (review F5, injeção-ssh): um dest começando com "-" poderia
		// ser reinterpretado pelo ssh como opção (ex.: -oProxyCommand=...).
		if strings.HasPrefix(dest, "-") {
			warns = append(warns, fmt.Sprintf("destino começa com '-', ignorado: %q", entry))
			continue
		}
		out = append(out, Machine{
			Name:      name,
			Dest:      dest,
			Port:      defaultSSHPort,
			RemoteCmd: remoteCmd,
			Source:    SourceEnv,
		})
	}
	return out, warns
}

// Registry guarda as máquinas conhecidas. Thread-safe: o hub lê daqui em
// handlers concorrentes.
type Registry struct {
	mu    sync.RWMutex
	order []string
	by    map[string]Machine
}

// NewRegistry cria o registro a partir da lista dada, preservando a ordem.
// Nome repetido: a primeira ocorrência vence.
func NewRegistry(ms []Machine) *Registry {
	r := &Registry{by: make(map[string]Machine, len(ms))}
	for _, m := range ms {
		if _, dup := r.by[m.Name]; dup {
			continue
		}
		r.by[m.Name] = m
		r.order = append(r.order, m.Name)
	}
	return r
}

// List devolve as máquinas na ordem de cadastro.
func (r *Registry) List() []Machine {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Machine, 0, len(r.order))
	for _, n := range r.order {
		out = append(out, r.by[n])
	}
	return out
}

// Get busca uma máquina pelo nome.
func (r *Registry) Get(name string) (Machine, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.by[name]
	return m, ok
}
