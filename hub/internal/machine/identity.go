package machine

import (
	"encoding/base64"
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

// Identity é um conjunto de credenciais reutilizável entre máquinas: o usuário
// remoto, a chave que o autentica e (opcionalmente) a senha guardada. É a
// "identity" do Termius, e é o que faz cadastrar cinco hosts não significar
// repetir usuário cinco vezes nem instalar cinco chaves diferentes.
//
// A chave é DA IDENTIDADE, não da máquina — foi a mudança de fundo do redesenho.
// Antes cada máquina tinha o seu par; agora o mesmo `vanessa` vale em todos os
// hosts com uma chave só.
type Identity struct {
	Name     string `json:"name"`
	Username string `json:"username"`
	// HasPassword diz se existe senha guardada, sem dizer qual. É tudo que o app
	// sabe do segredo: não há rota que devolva a senha, nem campo que a carregue.
	HasPassword bool `json:"has_password"`

	// KeyPath é o caminho da privada em /data/machines/keys/<identidade>. Interno:
	// o conteúdo da chave não sai do macmini e o caminho não interessa ao app.
	KeyPath string `json:"-"`
	// secret é a senha cifrada (AES-256-GCM, nonce embutido). Minúsculo de
	// propósito: fora do pacote não há como ler, nem por reflexão de encoding/json.
	secret []byte
}

// Erros do registro de identidades.
var (
	ErrDuplicateIdentity = errors.New("já existe uma identidade com esse nome")
	ErrIdentityNotFound  = errors.New("identidade não encontrada")
	ErrInvalidUsername   = errors.New("usuário inválido")
	// ErrIdentityInUse impede apagar identidade que alguma máquina usa: sem ela a
	// máquina viraria um host sem usuário nem chave, falhando na conexão seguinte
	// com um erro que não explica nada.
	ErrIdentityInUse = errors.New("a identidade está em uso por alguma máquina")
	// ErrNoPassword: pediram para instalar chave usando a senha guardada, e não há.
	ErrNoPassword = errors.New("a identidade não tem senha guardada")
)

// validUsername: conta remota. Sem "@" (senão o dest montado teria dois), sem
// espaço, e nunca começando com "-" — o mesmo cuidado do dest, porque o usuário
// entra na linha do ssh.
var validUsername = regexp.MustCompile(`^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$`)

// validateIdentity confere e normaliza nome e usuário.
func validateIdentity(id Identity) (Identity, error) {
	id.Name = strings.TrimSpace(id.Name)
	id.Username = strings.TrimSpace(id.Username)
	if !validName.MatchString(id.Name) || id.Name == "." || id.Name == ".." {
		return Identity{}, fmt.Errorf("%w: %q", ErrInvalidName, id.Name)
	}
	if !validUsername.MatchString(id.Username) {
		return Identity{}, fmt.Errorf("%w: %q", ErrInvalidUsername, id.Username)
	}
	return id, nil
}

// IdentityStore guarda as identidades. Mesma forma do Registry (ordem estável +
// mapa + persistência atômica), porque as duas coisas têm a mesma vida: nascem
// no cadastro e precisam sobreviver ao restart do container.
type IdentityStore struct {
	mu    sync.RWMutex
	order []string
	by    map[string]Identity
	// path é o arquivo em /data. Vazio = só memória (dev/teste).
	path string
	// box cifra as senhas. nil = hub sem CUTUQUE_IDENTITY_KEY: identidade
	// funciona, mas guardar senha é recusado com ErrNoSecretKey.
	box *secretBox
}

// NewIdentityStore cria o registro em memória, sem cifra. Para teste e para o
// modo dev sem /data.
func NewIdentityStore() *IdentityStore {
	return &IdentityStore{by: make(map[string]Identity)}
}

// NewIdentityStoreAt cria o registro persistente em path e configura a cifra a
// partir da chave em base64 (normalmente CUTUQUE_IDENTITY_KEY).
//
// Chave ausente não é erro: o hub sobe sem guardar senha. Chave PRESENTE e
// inválida é erro — deixar passar daria um hub que aceita cadastrar senha e
// falha só na hora de usar.
func NewIdentityStoreAt(path, keyB64 string) (*IdentityStore, error) {
	s := &IdentityStore{by: make(map[string]Identity), path: path}
	box, err := newSecretBox(keyB64)
	switch {
	case errors.Is(err, ErrNoSecretKey): // segue sem cifra
	case err != nil:
		return nil, err
	default:
		s.box = box
	}
	for _, id := range loadIdentities(path) {
		s.put(id)
	}
	return s, nil
}

// CanStorePassword diz se o hub está configurado para guardar senha. O app usa
// isto para não oferecer um campo que vai ser recusado.
func (s *IdentityStore) CanStorePassword() bool { return s != nil && s.box != nil }

func (s *IdentityStore) put(id Identity) {
	if _, dup := s.by[id.Name]; dup {
		return
	}
	s.by[id.Name] = id
	s.order = append(s.order, id.Name)
}

// diskIdentity é o formato em disco: o secret vai em base64 porque JSON não
// carrega bytes crus.
type diskIdentity struct {
	Name     string `json:"name"`
	Username string `json:"username"`
	KeyPath  string `json:"key_path,omitempty"`
	Secret   string `json:"secret,omitempty"`
}

func loadIdentities(path string) []Identity {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil // primeiro boot
	}
	var dis []diskIdentity
	if json.Unmarshal(b, &dis) != nil {
		return nil // corrompido: subir sem ele é melhor que não subir
	}
	out := make([]Identity, 0, len(dis))
	for _, d := range dis {
		id := Identity{Name: d.Name, Username: d.Username, KeyPath: d.KeyPath}
		if d.Secret != "" {
			if raw, err := base64.StdEncoding.DecodeString(d.Secret); err == nil {
				id.secret = raw
				id.HasPassword = true
			}
		}
		out = append(out, id)
	}
	return out
}

// persist grava o arquivo inteiro. Erro sobe: perder em silêncio uma identidade
// recém-criada deixaria as máquinas dela órfãs no próximo boot.
func (s *IdentityStore) persist() error {
	if s.path == "" {
		return nil
	}
	s.mu.RLock()
	dis := make([]diskIdentity, 0, len(s.order))
	for _, n := range s.order {
		id := s.by[n]
		d := diskIdentity{Name: id.Name, Username: id.Username, KeyPath: id.KeyPath}
		if len(id.secret) > 0 {
			d.Secret = base64.StdEncoding.EncodeToString(id.secret)
		}
		dis = append(dis, d)
	}
	s.mu.RUnlock()

	b, err := json.MarshalIndent(dis, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	// tmp + rename, 0600: o arquivo carrega segredo cifrado e os usuários remotos.
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Add cria a identidade. password vazia = sem senha guardada; com senha e sem
// cifra configurada, recusa (ErrNoSecretKey) em vez de gravar em claro.
func (s *IdentityStore) Add(id Identity, password string) (Identity, error) {
	id, err := validateIdentity(id)
	if err != nil {
		return Identity{}, err
	}
	sealed, err := s.sealIfAny(password)
	if err != nil {
		return Identity{}, err
	}
	id.secret = sealed
	id.HasPassword = len(sealed) > 0

	s.mu.Lock()
	if _, dup := s.by[id.Name]; dup {
		s.mu.Unlock()
		return Identity{}, fmt.Errorf("%w: %q", ErrDuplicateIdentity, id.Name)
	}
	s.put(id)
	s.mu.Unlock()

	if err := s.persist(); err != nil {
		return Identity{}, err
	}
	return id, nil
}

// sealIfAny cifra a senha, ou devolve nil se não houver senha para guardar.
func (s *IdentityStore) sealIfAny(password string) ([]byte, error) {
	if password == "" {
		return nil, nil
	}
	if s.box == nil {
		return nil, ErrNoSecretKey
	}
	return s.box.seal(password)
}

// Update altera o usuário e/ou a senha. Semântica dos parâmetros, escolhida para
// o PATCH não ter como apagar segredo por omissão:
//   - username vazio: mantém o atual
//   - password nil: mantém a senha atual
//   - password apontando para "": APAGA a senha guardada
//   - password apontando para texto: substitui
func (s *IdentityStore) Update(name, username string, password *string) (Identity, error) {
	s.mu.Lock()
	cur, ok := s.by[name]
	if !ok {
		s.mu.Unlock()
		return Identity{}, fmt.Errorf("%w: %q", ErrIdentityNotFound, name)
	}
	next := cur
	if u := strings.TrimSpace(username); u != "" {
		if !validUsername.MatchString(u) {
			s.mu.Unlock()
			return Identity{}, fmt.Errorf("%w: %q", ErrInvalidUsername, u)
		}
		next.Username = u
	}
	if password != nil {
		if *password == "" {
			next.secret = nil
		} else {
			if s.box == nil {
				s.mu.Unlock()
				return Identity{}, ErrNoSecretKey
			}
			sealed, err := s.box.seal(*password)
			if err != nil {
				s.mu.Unlock()
				return Identity{}, err
			}
			next.secret = sealed
		}
		next.HasPassword = len(next.secret) > 0
	}
	s.by[name] = next
	s.mu.Unlock()

	if err := s.persist(); err != nil {
		return Identity{}, err
	}
	return next, nil
}

// Remove apaga a identidade. inUse é consultado com o lock livre e diz se alguma
// máquina ainda a referencia — o store de identidades não conhece o registro de
// máquinas, e não deveria.
func (s *IdentityStore) Remove(name string, inUse func(string) bool) error {
	s.mu.RLock()
	_, ok := s.by[name]
	s.mu.RUnlock()
	if !ok {
		return fmt.Errorf("%w: %q", ErrIdentityNotFound, name)
	}
	if inUse != nil && inUse(name) {
		return fmt.Errorf("%w: %q", ErrIdentityInUse, name)
	}

	s.mu.Lock()
	delete(s.by, name)
	s.order = slices.DeleteFunc(s.order, func(n string) bool { return n == name })
	s.mu.Unlock()

	return s.persist()
}

// SetKeyPath grava onde ficou a chave da identidade (logo após o ssh-keygen).
func (s *IdentityStore) SetKeyPath(name, path string) error {
	s.mu.Lock()
	id, ok := s.by[name]
	if !ok {
		s.mu.Unlock()
		return fmt.Errorf("%w: %q", ErrIdentityNotFound, name)
	}
	id.KeyPath = path
	s.by[name] = id
	s.mu.Unlock()
	return s.persist()
}

// Password decifra e devolve a senha guardada. É o ÚNICO leitor do segredo, e
// existe para um chamador só: a instalação da chave, dentro do hub. Não há rota
// HTTP que chegue aqui — de propósito.
func (s *IdentityStore) Password(name string) (string, error) {
	s.mu.RLock()
	id, ok := s.by[name]
	s.mu.RUnlock()
	if !ok {
		return "", fmt.Errorf("%w: %q", ErrIdentityNotFound, name)
	}
	if len(id.secret) == 0 {
		return "", fmt.Errorf("%w: %q", ErrNoPassword, name)
	}
	if s.box == nil {
		return "", ErrSecretUnreadable
	}
	return s.box.open(id.secret)
}

// List devolve as identidades na ordem de cadastro.
func (s *IdentityStore) List() []Identity {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Identity, 0, len(s.order))
	for _, n := range s.order {
		out = append(out, s.by[n])
	}
	return out
}

// Get busca uma identidade pelo nome.
func (s *IdentityStore) Get(name string) (Identity, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.by[name]
	return id, ok
}
