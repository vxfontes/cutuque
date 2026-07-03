// Package devices mantém, de forma thread-safe, os device tokens registrados
// pelos apps para receber push via APNs. É a lista de destino do fan-out do
// Notifier (ver docs/02-arquitetura.md).
//
// Persistência opcional: NewAt(path) carrega/grava a lista em JSON no disco, para
// os devices sobreviverem a restart/deploy do hub (senão só o próximo boot do app
// os re-registra — e um push disparado nesse meio-tempo se perde). New() (sem
// path) segue só em memória, útil nos testes.
package devices

import (
	"encoding/json"
	"os"
	"sort"
	"sync"
	"time"
)

// Device é um destino de push registrado por um app.
type Device struct {
	Token        string    `json:"token"`
	Platform     string    `json:"platform"`
	RegisteredAt time.Time `json:"registered_at"`
}

// Store guarda os devices indexados pelo token. Seguro para uso concorrente.
type Store struct {
	mu      sync.RWMutex
	byToken map[string]Device
	now     func() time.Time // injetável nos testes
	path    string           // "" = só memória; senão persiste em JSON aqui

	// persistMu serializa as gravações em disco entre si. Sem ele, dois
	// persist() concorrentes correm no MESMO arquivo tmp (path+".tmp") e o que
	// termina por último — não o logicamente mais recente — vence. É uma corrida
	// de I/O do SO, invisível ao -race (não é memória Go). Ver review SEC-105.
	persistMu sync.Mutex
}

// New cria um Store vazio, só em memória (sem persistência).
func New() *Store {
	return &Store{
		byToken: make(map[string]Device),
		now:     time.Now,
	}
}

// NewAt cria um Store que persiste a lista em JSON no arquivo path e carrega o
// que já houver lá (os devices sobrevivem a restart/deploy do hub). Erros de
// leitura são tolerados (arquivo ausente/corrompido → começa vazio), pois o app
// re-registra no próximo foreground de qualquer forma.
func NewAt(path string) *Store {
	s := New()
	s.path = path
	s.load()
	return s
}

// load lê os devices do disco para a memória (best-effort). Chamado só no boot.
func (s *Store) load() {
	if s.path == "" {
		return
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	var list []Device
	if err := json.Unmarshal(b, &list); err != nil {
		return
	}
	s.mu.Lock()
	for _, d := range list {
		if d.Token != "" {
			s.byToken[d.Token] = d
		}
	}
	s.mu.Unlock()
}

// persist grava a lista atual no disco de forma atômica (tmp + rename), para o
// arquivo nunca ficar meio-escrito se o hub morrer no meio. No-op sem path.
// Deve ser chamado FORA do lock de escrita (usa List(), que faz RLock).
//
// persistMu serializa toda a seção snapshot→escrita→rename: sem ele, gravações
// concorrentes disputariam o mesmo arquivo tmp e o resultado final poderia não
// refletir o último estado lógico (SEC-105).
func (s *Store) persist() {
	if s.path == "" {
		return
	}
	s.persistMu.Lock()
	defer s.persistMu.Unlock()

	b, err := json.Marshal(s.List())
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

// Upsert registra (ou reafirma) um device. Re-registrar o mesmo token preserva o
// RegisteredAt original (o iOS reenvia o token a cada boot; não é um device novo).
func (s *Store) Upsert(token, platform string) Device {
	s.mu.Lock()
	if existing, ok := s.byToken[token]; ok {
		existing.Platform = platform
		s.byToken[token] = existing
		s.mu.Unlock()
		s.persist()
		return existing
	}
	d := Device{Token: token, Platform: platform, RegisteredAt: s.now()}
	s.byToken[token] = d
	s.mu.Unlock()
	s.persist()
	return d
}

// List devolve uma cópia dos devices, ordenada por RegisteredAt (mais antigo
// primeiro) para dar ordem determinística ao fan-out e aos testes.
func (s *Store) List() []Device {
	s.mu.RLock()
	out := make([]Device, 0, len(s.byToken))
	for _, d := range s.byToken {
		out = append(out, d)
	}
	s.mu.RUnlock()

	sort.Slice(out, func(i, j int) bool {
		if out[i].RegisteredAt.Equal(out[j].RegisteredAt) {
			return out[i].Token < out[j].Token
		}
		return out[i].RegisteredAt.Before(out[j].RegisteredAt)
	})
	return out
}

// Remove apaga um device pelo token. Idempotente (no-op se não existir); usado
// pelo Notifier ao receber 410 Unregistered da APNs.
func (s *Store) Remove(token string) {
	s.mu.Lock()
	delete(s.byToken, token)
	s.mu.Unlock()
	s.persist()
}
