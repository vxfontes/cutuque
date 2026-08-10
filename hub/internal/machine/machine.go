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

// maxPort é o teto de uma porta TCP. Existe porque `Port` é `int`: sem o teto,
// uma porta digitada errada (70000) é guardada sem reclamação e só falha muito
// depois, na hora de conectar, com erro do ssh no lugar do erro do cadastro.
const maxPort = 65535

// Machine é uma máquina alcançável por ssh.
//
// Duas naturezas convivem aqui, e a diferença está em quem define o usuário:
//
//   - máquina de env/local: o `Dest` é a verdade (alias do ~/.ssh/config ou
//     user@host, escrito à mão no hub.env). Host e Identity ficam vazios.
//   - máquina do app: a verdade é `Host` + `Identity`, e o `Dest` é DERIVADO
//     (usuário da identidade + "@" + host). Ele continua existindo porque todo o
//     resto do hub — launcher, dirs, PTY — já fala em dest; o Registry preenche
//     na leitura para que não exista um só ponto onde alguém esqueça de resolver.
type Machine struct {
	Name string `json:"name"`
	Dest string `json:"dest"` // alias do ~/.ssh/config ou user@host
	Port int    `json:"port"`
	// Host é o hostname ou IP puro, sem usuário. Só para máquina do app.
	Host string `json:"host,omitempty"`
	// Identity é o nome da identidade que autentica nesta máquina. Só para app.
	Identity string `json:"identity,omitempty"`
	// OS é o sistema detectado no cadastro ("Darwin 24.5.0", "Ubuntu 24.04"),
	// para o app escolher o ícone. Vazio = ainda não detectado.
	OS string `json:"os,omitempty"`
	// Theme é o nome do tema do terminal escolhido para esta máquina. Vazio =
	// o padrão do app. O hub só guarda: quem sabe desenhar cor é o app.
	Theme string `json:"theme,omitempty"`
	// Icon é o ícone escolhido À MÃO para esta máquina. Vazio = automático, e aí
	// o app decide pelo OS detectado. Existe porque a detecção pode falhar para
	// sempre num host (ssh que não devolve `uname`, shell restrito) e sem isto
	// aquele host ficaria com o ícone genérico sem recurso. Mesma divisão do
	// Theme: o hub guarda a escolha, o app sabe desenhá-la.
	Icon string `json:"icon,omitempty"`
	// RemoteCmd é o caminho do agente remoto (3º campo do CUTUQUE_SSH_TARGETS).
	// Vazio = default. Não é exposto ao app: é detalhe interno do hub.
	RemoteCmd string `json:"-"`
	Source    Source `json:"source"`
	// KeyPath é o caminho da chave privada em /data/machines/keys/<nome>. Depois
	// do redesenho a chave é DA IDENTIDADE: para máquina do app este campo é
	// preenchido na leitura, a partir dela. Só sobrevive gravado como resíduo dos
	// cadastros anteriores à migração. NUNCA vai para o app: o conteúdo da chave
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
	ErrDuplicateHost = errors.New("já existe uma máquina com esse destino")
	ErrNotFound      = errors.New("máquina não encontrada")
	ErrReadOnly      = errors.New("máquina do hub.env não é editável pelo app")
	ErrInvalidName   = errors.New("nome inválido")
	ErrInvalidDest   = errors.New("destino inválido")
	ErrInvalidLook   = errors.New("aparência inválida")
)

// validName limita o nome ao que é seguro em URL E em caminho de arquivo: o
// nome vira segmento de rota e nome do arquivo da chave em /data/machines/keys.
// Sem isso, "../.." escaparia da pasta de chaves.
var validName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// validLook confere id de tema e de ícone. O hub valida a FORMA, não a lista:
// quem conhece os temas e os ícones é o app, e uma lista fechada aqui obrigaria
// a um deploy do hub para cada tema novo. O app já cai no Padrão/Automático
// quando não reconhece um id (`TerminalPalette.byID`, `MachineIcon.byID`), então
// um valor desconhecido aqui é inofensivo — o que não pode é entrar lixo de
// tamanho arbitrário no registro. Vazio é válido e significa Padrão/Automático:
// é conferido antes desta regex.
var validLook = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$`)

// validate confere nome, host e identidade de uma máquina vinda do app, e
// normaliza a porta. Devolve a máquina saneada.
//
// Depois do redesenho o app manda `host` + `identity`, nunca `dest`: o usuário
// mora na identidade. Um dest que chegasse aqui é ignorado — aceitá-lo deixaria
// o app contornar a identidade e escolher a conta remota por outro caminho.
func validate(m Machine) (Machine, error) {
	m.Name = strings.TrimSpace(m.Name)
	m.Host = strings.TrimSpace(m.Host)
	m.Identity = strings.TrimSpace(m.Identity)
	if !validName.MatchString(m.Name) || m.Name == "." || m.Name == ".." {
		return Machine{}, fmt.Errorf("%w: %q", ErrInvalidName, m.Name)
	}
	if m.Host == "" {
		return Machine{}, fmt.Errorf("%w: host vazio", ErrInvalidDest)
	}
	// Mesma defesa do ParseSSHTargets: um host começando com "-" seria
	// reinterpretado pelo ssh como opção (ex.: -oProxyCommand=...).
	if strings.HasPrefix(m.Host, "-") {
		return Machine{}, fmt.Errorf("%w: host começa com '-'", ErrInvalidDest)
	}
	// "@" no host significa que o usuário veio grudado — é o formato antigo. O
	// usuário agora é da identidade, e deixar passar daria um dest com dois "@".
	if strings.Contains(m.Host, "@") {
		return Machine{}, fmt.Errorf("%w: o host não leva usuário (isso é da identidade)", ErrInvalidDest)
	}
	if !validName.MatchString(m.Identity) {
		return Machine{}, fmt.Errorf("%w: identidade %q", ErrInvalidDest, m.Identity)
	}
	if err := checkLook(m.Theme, m.Icon); err != nil {
		return Machine{}, err
	}
	// Porta <= 0 é "não informada" (o app manda o campo vazio) e vira a padrão.
	// Acima do teto é dado impossível: recusa aqui, onde a mensagem consegue
	// dizer o que está errado.
	if m.Port <= 0 {
		m.Port = defaultSSHPort
	}
	if m.Port > maxPort {
		return Machine{}, fmt.Errorf("%w: porta %d (o máximo é %d)", ErrInvalidDest, m.Port, maxPort)
	}
	m.Dest = "" // derivado na leitura, nunca guardado
	return m, nil
}

// checkLook confere tema e ícone. Vazio passa nos dois: é o valor que significa
// "usa o padrão", e é assim que se volta atrás de uma escolha.
func checkLook(theme, icon string) error {
	if theme != "" && !validLook.MatchString(theme) {
		return fmt.Errorf("%w: tema %q", ErrInvalidLook, theme)
	}
	if icon != "" && !validLook.MatchString(icon) {
		return fmt.Errorf("%w: ícone %q", ErrInvalidLook, icon)
	}
	return nil
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
	// idents resolve o usuário das máquinas do app. nil = sem cadastro (o hub
	// roda só com as máquinas do hub.env, que já trazem o dest pronto).
	idents *IdentityStore
	// saveMu serializa a GRAVAÇÃO. Não é o `mu`: o snapshot solta o lock de
	// leitura antes de marshalar e escrever, então duas gravações concorrentes
	// disputavam o mesmo `.tmp` — uma podia renomear o arquivo no meio da
	// escrita da outra (JSON truncado em /data) ou publicar um snapshot velho
	// por cima do novo. Ver o comentário do persist.
	saveMu sync.Mutex
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
//
// idents pode ser nil (hub sem cadastro pelo app). Quando presente, é também
// quem recebe as identidades criadas pela migração do formato antigo.
func NewRegistryAt(path string, ms []Machine, idents *IdentityStore) *Registry {
	r := NewRegistry(ms)
	r.path = path
	r.idents = idents
	migrou := false
	for _, m := range loadDisk(path) {
		if _, taken := r.by[m.Name]; taken {
			continue
		}
		m.Source = SourceApp // o que veio do disco é sempre cadastro do app
		if migrado, ok := migraLegado(m, idents); ok {
			m = migrado
			migrou = true
		}
		r.put(m)
	}
	// Regrava só se algo mudou de forma: um boot normal não deve reescrever
	// /data à toa.
	if migrou {
		_ = r.persist()
	}
	return r
}

// migraLegado converte uma máquina do formato anterior ao redesenho — que
// guardava `dest` ("user@host") e tinha a chave no nome DA MÁQUINA — para o
// formato novo, criando uma identidade para ela.
//
// A identidade nasce uma POR MÁQUINA, com o nome da máquina, e herda a chave que
// já está instalada no destino. Não se tenta agrupar máquinas pelo mesmo usuário:
// duas máquinas com o usuário `vx` têm chaves diferentes já gravadas nos dois
// authorized_keys, e uni-las numa identidade só deixaria uma das duas sem poder
// entrar. Consolidar é escolha da usuária, depois, criando uma identidade nova.
func migraLegado(m Machine, idents *IdentityStore) (Machine, bool) {
	if m.Identity != "" || m.Dest == "" || idents == nil {
		return m, false
	}
	user := userOf(m.Dest)
	host := hostOf(m.Dest)
	if user == "" || host == "" {
		// Sem usuário no dest não há identidade a montar (era alias do ssh
		// config). Fica como está: o dest continua servindo.
		return m, false
	}
	id, err := idents.Add(Identity{Name: m.Name, Username: user}, "")
	if err != nil {
		if existente, ok := idents.Get(m.Name); ok {
			id = existente // já migrada num boot anterior
		} else {
			return m, false
		}
	}
	if m.KeyPath != "" && id.KeyPath == "" {
		_ = idents.SetKeyPath(id.Name, m.KeyPath)
	}
	m.Host = host
	m.Identity = id.Name
	m.Dest = ""
	return m, true
}

// resolve preenche o Dest derivado das máquinas do app. Fica no Get/List de
// propósito: se cada chamador tivesse de resolver, bastaria um esquecer para o
// ssh sair sem usuário e falhar num ponto distante da causa.
//
// O store vem por parâmetro, lido sob o lock do registro pelo chamador: assim a
// consulta ao IdentityStore (que tem lock próprio) acontece com o lock do
// Registry já liberado — aninhar os dois é como se inventa um deadlock.
func resolve(m Machine, idents *IdentityStore) Machine {
	if m.Identity == "" || idents == nil {
		return m
	}
	if id, ok := idents.Get(m.Identity); ok {
		m.Dest = id.Username + "@" + m.Host
		// A chave também é da identidade. Resolver aqui é o que faz o
		// launcher.RegisterMachine continuar funcionando sem mudança: ele lê
		// m.KeyPath para montar o `ssh -i`, e agora recebe o da identidade.
		if id.KeyPath != "" {
			m.KeyPath = id.KeyPath
		}
	}
	return m
}

// mesmaMaquina diz se a cadastrada `e` já é a mesma caixa que a nova `m` (cujo
// dest resolvido é `novoDest`). Existe porque o MacBook entrou duas vezes — env
// "macbook" + app "mac" — e cada pane dele apareceu em dobro no "Ao vivo".
//
// A porta faz parte da identidade: o mesmo host noutra porta pode ser mesmo
// outra máquina (contêiner, VM atrás de NAT), e recusar ali seria mentira.
//
// LIMITE CONHECIDO: destino do env escrito como ALIAS do ~/.ssh/config
// ("mac-cutuque") não casa com o IP do cadastro do app — quem sabe resolver o
// alias é o ssh, não o hub. Foi exatamente assim que o par mac/macbook passou.
// O que fecha esse buraco é o fingerprint do host, que a máquina do env não tem
// no cadastro.
func mesmaMaquina(e, m Machine, novoDest string) bool {
	if e.Port != m.Port {
		return false
	}
	if e.Host != "" { // cadastro do app: o host cru é a verdade
		return e.Host == m.Host
	}
	// env/local: o Dest guardado é a verdade, e pode vir com ou sem usuário.
	return e.Dest != "" && (e.Dest == novoDest || e.Dest == m.Host)
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

// UseIdentities liga o registro a um store de identidades depois da construção.
// Existe para o modo em memória (dev e teste), onde o NewRegistry não recebe o
// store; em produção quem liga é o NewRegistryAt.
func (r *Registry) UseIdentities(s *IdentityStore) {
	r.mu.Lock()
	r.idents = s
	r.mu.Unlock()
}

// identityStore devolve o store sob o lock, para o resolve rodar com ele livre.
func (r *Registry) identityStore() *IdentityStore {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.idents
}

// diskMachine é o formato em disco. Espelha a Machine, mas com o KeyPath
// incluído — em /data ele PRECISA ser gravado; o que ele não pode é ir ao app.
//
// `dest` continua lido para as máquinas gravadas antes do redesenho (a migração
// as converte no boot), mas não é mais escrito: para máquina do app ele é
// derivado, e gravar valor derivado é convidar as duas versões a divergirem.
type diskMachine struct {
	Name            string `json:"name"`
	Dest            string `json:"dest,omitempty"`
	Port            int    `json:"port"`
	Host            string `json:"host,omitempty"`
	Identity        string `json:"identity,omitempty"`
	OS              string `json:"os,omitempty"`
	Theme           string `json:"theme,omitempty"`
	Icon            string `json:"icon,omitempty"`
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
			Host: d.Host, Identity: d.Identity, OS: d.OS, Theme: d.Theme,
			Icon: d.Icon, KeyPath: d.KeyPath, HostFingerprint: d.HostFingerprint,
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
//
// Uma gravação por vez (`saveMu`), e o snapshot vem DENTRO dela: sem isso, dois
// pedidos concorrentes — dois aparelhos dela mexendo na mesma máquina — escrevem
// no mesmo `.tmp` e um `Rename` pode publicar o arquivo do outro pela metade, ou
// um snapshot mais velho pode chegar por último e o /data ficar divergindo da
// memória até a próxima escrita. Serializado, quem grava por último é quem tirou
// o snapshot por último, e o último snapshot é sempre >= a última mudança.
func (r *Registry) persist() error {
	if r.path == "" {
		return nil
	}
	r.saveMu.Lock()
	defer r.saveMu.Unlock()

	r.mu.RLock()
	dms := make([]diskMachine, 0, len(r.order))
	for _, n := range r.order {
		m := r.by[n]
		if m.Source != SourceApp {
			continue
		}
		dms = append(dms, diskMachine{
			Name: m.Name, Port: m.Port,
			Host: m.Host, Identity: m.Identity, OS: m.OS, Theme: m.Theme,
			Icon: m.Icon, KeyPath: m.KeyPath, HostFingerprint: m.HostFingerprint,
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
// máquina do env — é recusado, e DESTINO já cadastrado também: o nome não é a
// identidade da máquina.
func (r *Registry) Add(m Machine) (Machine, error) {
	m, err := validate(m)
	if err != nil {
		return Machine{}, err
	}
	m.Source = SourceApp
	m.RemoteCmd = "" // o app não define caminho de binário na máquina

	// Dest da nova, resolvido com o lock do registro LIVRE (o IdentityStore tem
	// lock próprio; aninhar os dois é como se inventa um deadlock — ver resolve).
	novoDest := resolve(m, r.identityStore()).Dest

	r.mu.Lock()
	if _, dup := r.by[m.Name]; dup {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrDuplicateName, m.Name)
	}
	// A comparação abaixo só lê campos GUARDADOS (Host/Port das do app, Dest
	// literal das do env), nunca resolvido — por isso não precisa do store aqui
	// dentro e a checagem fica atômica com a inserção.
	for _, nome := range r.order {
		if e := r.by[nome]; mesmaMaquina(e, m, novoDest) {
			r.mu.Unlock()
			return Machine{}, fmt.Errorf("%w: %q já aponta para lá", ErrDuplicateHost, nome)
		}
	}
	r.put(m)
	r.mu.Unlock()

	if err := r.persist(); err != nil {
		return Machine{}, err
	}
	return resolve(m, r.identityStore()), nil
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
	//
	// Campo vazio no patch mantém o atual — é PATCH, não PUT: a página de edição
	// do app manda o que mexeu.
	alvo := Machine{Name: name, Host: patch.Host, Identity: patch.Identity, Port: patch.Port}
	if alvo.Host == "" {
		alvo.Host = cur.Host
	}
	if alvo.Identity == "" {
		alvo.Identity = cur.Identity
	}
	if alvo.Port <= 0 {
		alvo.Port = cur.Port
	}
	next, err := validate(alvo)
	if err != nil {
		r.mu.Unlock()
		return Machine{}, err
	}
	next.Source = SourceApp
	next.KeyPath = cur.KeyPath
	next.OS = cur.OS
	next.Theme = cur.Theme
	if patch.Theme != "" {
		next.Theme = patch.Theme
	}
	// Aparência não é assunto deste patch: quem mexe em tema e ícone é o
	// SetAppearance, que sabe apagar a escolha (vazio = padrão) — coisa que aqui
	// seria impossível, porque vazio significa "mantém". O `Theme` acima
	// sobrevive só pelos chamadores antigos.
	next.Icon = cur.Icon
	// O fingerprint pertence a um (host, porta). Apontar a máquina para outro
	// lugar derruba a confirmação: senão o hub acharia que já confiou num host
	// que a usuária nunca conferiu. Trocar de IDENTIDADE não derruba — o
	// fingerprint é do host, e quem entra nele é assunto separado. Mas derruba o
	// SO detectado, que é do par (host, conta).
	if next.Host == cur.Host && next.Port == cur.Port {
		next.HostFingerprint = cur.HostFingerprint
	} else {
		next.OS = ""
	}
	r.by[name] = next
	r.mu.Unlock()

	if err := r.persist(); err != nil {
		return Machine{}, err
	}
	return resolve(next, r.identityStore()), nil
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

// SetOS grava o sistema detectado no host. Só descritivo: o app usa para o
// ícone, nada no hub decide nada com isto.
func (r *Registry) SetOS(name, os string) error {
	return r.setField(name, func(m *Machine) { m.OS = os })
}

// SetTheme grava o tema do terminal escolhido para a máquina.
func (r *Registry) SetTheme(name, theme string) error {
	return r.setField(name, func(m *Machine) { m.Theme = theme })
}

// SetAppearance troca tema e ícone da máquina, com semântica de SUBSTITUIÇÃO:
// vazio não significa "mantém" (como no Update), significa "volta ao padrão".
// Sem isso não haveria como desfazer uma escolha de tema — o id do tema Padrão é
// justamente a string vazia.
//
// Nada aqui alcança host, porta, identidade ou fingerprint, e é de propósito:
// aparência não afeta conexão, então a rota que a muda não deve nem ter como
// derrubar uma confiança que a usuária conferiu à mão.
func (r *Registry) SetAppearance(name, theme, icon string) (Machine, error) {
	theme, icon = strings.TrimSpace(theme), strings.TrimSpace(icon)
	if err := checkLook(theme, icon); err != nil {
		return Machine{}, err
	}
	r.mu.Lock()
	m, ok := r.by[name]
	if !ok {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrNotFound, name)
	}
	if !m.Editable() {
		r.mu.Unlock()
		return Machine{}, fmt.Errorf("%w: %q", ErrReadOnly, name)
	}
	m.Theme, m.Icon = theme, icon
	r.by[name] = m
	idents := r.idents
	r.mu.Unlock()

	if err := r.persist(); err != nil {
		return Machine{}, err
	}
	return resolve(m, idents), nil
}

// UsesIdentity diz se alguma máquina usa a identidade dada. É o que impede
// apagar identidade em uso — passado como callback para o IdentityStore.Remove,
// que não conhece máquinas.
func (r *Registry) UsesIdentity(identity string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, m := range r.by {
		if m.Identity == identity {
			return true
		}
	}
	return false
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

// List devolve as máquinas na ordem de cadastro, com o Dest já resolvido.
func (r *Registry) List() []Machine {
	r.mu.RLock()
	brutas := make([]Machine, 0, len(r.order))
	for _, n := range r.order {
		brutas = append(brutas, r.by[n])
	}
	idents := r.idents
	r.mu.RUnlock()

	out := make([]Machine, 0, len(brutas))
	for _, m := range brutas {
		out = append(out, resolve(m, idents))
	}
	return out
}

// Get busca uma máquina pelo nome, com o Dest já resolvido.
func (r *Registry) Get(name string) (Machine, bool) {
	r.mu.RLock()
	m, ok := r.by[name]
	idents := r.idents
	r.mu.RUnlock()
	if !ok {
		return Machine{}, false
	}
	return resolve(m, idents), true
}
