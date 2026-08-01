// Package machine mantém o registro das máquinas SSH que o hub conhece: as que
// vêm do CUTUQUE_SSH_TARGETS (Source=env, imutáveis pelo app) e, a partir da
// F3, as cadastradas pelo app (Source=app). Nesta fase o registro é só de
// leitura e vive em memória — persistência nasce quando houver o que persistir.
package machine

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
)

// Source diz de onde a máquina veio. Máquina de env não é editável pelo app:
// quem manda nela é o hub.env.
type Source string

const (
	SourceEnv Source = "env"
	SourceApp Source = "app"
	// SourceLocal é a máquina onde o próprio hub roda, sem ssh no meio. Existe
	// só no modo dev (sem CUTUQUE_SSH_TARGETS), espelhando o LocalTarget
	// implícito do buildTargets.
	SourceLocal Source = "local"
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
	// KeyPath é o caminho da chave privada em /data/machines/keys/<nome>, para
	// máquinas cadastradas pelo app. NUNCA vai para o app: o conteúdo da chave
	// não sai do macmini, e o caminho é detalhe interno.
	KeyPath string `json:"-"`
	// HostFingerprint é a impressão digital da chave do host, capturada no
	// cadastro e confirmada pela usuária (TOFU). Vai para o app: é o que ela
	// confere. Vazio = ainda não confiado; conexão não deve prosseguir.
	HostFingerprint string `json:"host_fingerprint,omitempty"`
}

// Editable diz se o app pode alterar ou remover a máquina. Só as cadastradas
// pelo app: quem manda nas de env é o hub.env, e a local é o próprio hub.
func (m Machine) Editable() bool { return m.Source == SourceApp }

// Erros do registro. Tipados para o handler traduzir em status HTTP sem
// comparar texto.
var (
	ErrDuplicateName = errors.New("já existe uma máquina com esse nome")
	ErrNotFound      = errors.New("máquina não encontrada")
	ErrReadOnly      = errors.New("máquina do hub.env não é editável pelo app")
	ErrInvalidName   = errors.New("nome inválido")
	ErrInvalidDest   = errors.New("destino inválido")
)

// validName limita o nome ao que é seguro em URL E em caminho de arquivo: o
// nome vira segmento de rota e nome do arquivo da chave em /data/machines/keys.
// Sem isso, "../.." escaparia da pasta de chaves.
var validName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// validate confere nome e destino de uma máquina vinda do app, e normaliza a
// porta. Devolve a máquina saneada.
func validate(m Machine) (Machine, error) {
	m.Name = strings.TrimSpace(m.Name)
	m.Dest = strings.TrimSpace(m.Dest)
	if !validName.MatchString(m.Name) || m.Name == "." || m.Name == ".." {
		return Machine{}, fmt.Errorf("%w: %q", ErrInvalidName, m.Name)
	}
	if m.Dest == "" {
		return Machine{}, fmt.Errorf("%w: vazio", ErrInvalidDest)
	}
	// Mesma defesa do ParseSSHTargets: um dest começando com "-" seria
	// reinterpretado pelo ssh como opção (ex.: -oProxyCommand=...).
	if strings.HasPrefix(m.Dest, "-") {
		return Machine{}, fmt.Errorf("%w: começa com '-'", ErrInvalidDest)
	}
	if m.Port <= 0 {
		m.Port = defaultSSHPort
	}
	return m, nil
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
	// path é o arquivo de fallback em /data. Vazio = só memória (dev/teste).
	path string
}

// NewRegistry cria o registro a partir da lista dada, preservando a ordem.
// Nome repetido: a primeira ocorrência vence. Sem persistência (modo dev/teste).
func NewRegistry(ms []Machine) *Registry {
	r := &Registry{by: make(map[string]Machine, len(ms))}
	for _, m := range ms {
		r.put(m)
	}
	return r
}

// NewRegistryAt cria o registro com persistência em path, carregando o que já
// estiver em disco DEPOIS das máquinas do env — o env é a fonte da verdade das
// máquinas dele, e uma entrada antiga em disco não pode sequestrar um nome que
// hoje pertence ao hub.env. Disco ilegível ou corrompido é ignorado: o hub sobe
// com o que o env deu, em vez de não subir.
func NewRegistryAt(path string, ms []Machine) *Registry {
	r := NewRegistry(ms)
	r.path = path
	for _, m := range loadDisk(path) {
		if _, taken := r.by[m.Name]; taken {
			continue
		}
		m.Source = SourceApp // o que veio do disco é sempre cadastro do app
		r.put(m)
	}
	return r
}

// put insere sem lock e sem persistir (uso interno na construção e nas
// mutações, que já seguram o lock). Nome repetido é ignorado.
func (r *Registry) put(m Machine) {
	if _, dup := r.by[m.Name]; dup {
		return
	}
	r.by[m.Name] = m
	r.order = append(r.order, m.Name)
}

// diskMachine é o formato em disco. Espelha a Machine, mas com o KeyPath
// incluído — em /data ele PRECISA ser gravado; o que ele não pode é ir ao app.
type diskMachine struct {
	Name            string `json:"name"`
	Dest            string `json:"dest"`
	Port            int    `json:"port"`
	KeyPath         string `json:"key_path,omitempty"`
	HostFingerprint string `json:"host_fingerprint,omitempty"`
}

func loadDisk(path string) []Machine {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil // arquivo ainda não existe: primeiro boot
	}
	var dms []diskMachine
	if json.Unmarshal(b, &dms) != nil {
		return nil // corrompido: melhor subir sem ele do que não subir
	}
	out := make([]Machine, 0, len(dms))
	for _, d := range dms {
		out = append(out, Machine{
			Name: d.Name, Dest: d.Dest, Port: d.Port,
			KeyPath: d.KeyPath, HostFingerprint: d.HostFingerprint,
			Source: SourceApp,
		})
	}
	return out
}

// persist grava as máquinas do APP (as de env vêm do hub.env a cada boot, e as
// gravar aqui as congelaria). Chame com o lock de leitura livre.
//
// Diferente do board, o erro sobe: perder em silêncio um cadastro que acabou de
// instalar uma chave na máquina remota deixaria a usuária sem saber que precisa
// refazer tudo.
func (r *Registry) persist() error {
	if r.path == "" {
		return nil
	}
	r.mu.RLock()
	dms := make([]diskMachine, 0, len(r.order))
	for _, n := range r.order {
		m := r.by[n]
		if m.Source != SourceApp {
			continue
		}
		dms = append(dms, diskMachine{
			Name: m.Name, Dest: m.Dest, Port: m.Port,
			KeyPath: m.KeyPath, HostFingerprint: m.HostFingerprint,
		})
	}
	r.mu.RUnlock()

	b, err := json.MarshalIndent(dms, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.path), 0o700); err != nil {
		return err
	}
	// tmp + rename: uma queda no meio da escrita não pode deixar o registro
	// truncado. 0600 — o arquivo lista os destinos ssh da usuária.
	tmp := r.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.path)
}

// Add cadastra uma máquina nova vinda do app. Nome e destino são validados; a
// origem é sempre app (o app não escolhe). Nome já usado — inclusive por
// máquina do env — é recusado.
func (r *Registry) Add(m Machine) (Machine, error) {
	m, err := validate(m)
	if err != nil {
		return Machine{}, err
	}
	m.Source = SourceApp
	m.RemoteCmd = "" // o app não define caminho de binário na máquina

	r.mu.Lock()
	if _, dup := r.by[m.Name]; dup {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrDuplicateName, m.Name)
	}
	r.put(m)
	r.mu.Unlock()

	if err := r.persist(); err != nil {
		return Machine{}, err
	}
	return m, nil
}

// Update altera destino e porta de uma máquina do app. Chave e fingerprint são
// do hub e NÃO podem vir do app: trocá-los por PATCH deixaria outro host se
// passar pelo cadastrado.
func (r *Registry) Update(name string, patch Machine) (Machine, error) {
	r.mu.Lock()
	cur, ok := r.by[name]
	if !ok {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrNotFound, name)
	}
	if !cur.Editable() {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrReadOnly, name)
	}
	// Valida sobre o nome atual: o nome não muda por PATCH (é a chave da URL e
	// o nome do arquivo da chave privada).
	next, err := validate(Machine{Name: name, Dest: patch.Dest, Port: patch.Port})
	if err != nil {
		r.mu.Unlock()
		return Machine{}, err
	}
	next.Source = SourceApp
	next.KeyPath = cur.KeyPath
	next.HostFingerprint = cur.HostFingerprint
	r.by[name] = next
	r.mu.Unlock()

	if err := r.persist(); err != nil {
		return Machine{}, err
	}
	return next, nil
}

// Remove tira uma máquina do app do registro. Não apaga a chave privada: isso é
// do handler, que sabe onde ela mora.
func (r *Registry) Remove(name string) error {
	r.mu.Lock()
	cur, ok := r.by[name]
	if !ok {
		r.mu.Unlock()
		return fmt.Errorf("%w: %q", ErrNotFound, name)
	}
	if !cur.Editable() {
		r.mu.Unlock()
		return fmt.Errorf("%w: %q", ErrReadOnly, name)
	}
	delete(r.by, name)
	r.order = slices.DeleteFunc(r.order, func(n string) bool { return n == name })
	r.mu.Unlock()

	return r.persist()
}

// SetKeyPath grava onde ficou a chave privada da máquina (chamado logo após o
// ssh-keygen). Interno do hub — não há rota que exponha isso.
func (r *Registry) SetKeyPath(name, path string) error {
	return r.setField(name, func(m *Machine) { m.KeyPath = path })
}

// SetFingerprint grava a impressão digital do host confiada pela usuária
// (TOFU). Só depois disso a conexão àquela máquina deve prosseguir.
func (r *Registry) SetFingerprint(name, fp string) error {
	return r.setField(name, func(m *Machine) { m.HostFingerprint = fp })
}

func (r *Registry) setField(name string, apply func(*Machine)) error {
	r.mu.Lock()
	m, ok := r.by[name]
	if !ok {
		r.mu.Unlock()
		return fmt.Errorf("%w: %q", ErrNotFound, name)
	}
	apply(&m)
	r.by[name] = m
	r.mu.Unlock()
	return r.persist()
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
