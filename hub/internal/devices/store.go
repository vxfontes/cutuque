// Package devices mantém, em memória e de forma thread-safe, os device tokens
// registrados pelos apps para receber push via APNs. É a lista de destino do
// fan-out do Notifier (ver docs/02-arquitetura.md). Sem persistência: ao subir,
// o hub começa vazio e os apps se re-registram (o token é reenviado a cada boot
// do app pelo iOS).
package devices

import (
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
}

// New cria um Store vazio.
func New() *Store {
	return &Store{
		byToken: make(map[string]Device),
		now:     time.Now,
	}
}

// Upsert registra (ou reafirma) um device. Re-registrar o mesmo token preserva o
// RegisteredAt original (o iOS reenvia o token a cada boot; não é um device novo).
func (s *Store) Upsert(token, platform string) Device {
	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.byToken[token]; ok {
		existing.Platform = platform
		s.byToken[token] = existing
		return existing
	}
	d := Device{Token: token, Platform: platform, RegisteredAt: s.now()}
	s.byToken[token] = d
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
	defer s.mu.Unlock()
	delete(s.byToken, token)
}
