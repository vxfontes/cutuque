package machine

import (
	"sync"
	"testing"
)

// Testes de concorrência da derivação de `dest`.
//
// Existem por causa de uma corrida de dados encontrada na revisão do redesenho e
// corrigida antes de rodar: `resolve` lia o campo `r.idents` SEM o lock enquanto
// `UseIdentities` o escrevia COM o lock. O resto da suíte é sequencial, então
// `-race` sozinho não guardava isso — sem duas goroutines de verdade, o detector
// não tem o que detectar.
//
// O que estes testes NÃO provam, apesar de ser o que se esperaria de um arquivo
// com este nome: ausência de deadlock entre o Registry e o IdentityStore. Fui
// checar e o ciclo não existe — o `Remove` solta o lock antes de chamar `inUse`
// (que reentra no Registry), e o único caminho registro→store é o `resolve`.
// Tentei escrever o teste do deadlock de duas formas e as duas passaram até com a
// trava revertida numa cópia descartável, porque `sync.RWMutex` deixa reentrar em
// `RLock` na mesma goroutine. Fica registrado para o próximo não gastar a tarde
// de novo: se um dia alguém fizer o store chamar de volta o registro segurando o
// lock de **escrita**, aí sim aparece deadlock — e aí um teste faz sentido.
//
// Rodar: go test -race ./internal/machine/ -run Corrida

// TestCorridaEntreUseIdentitiesEList é o caso exato do bug: trocar o store de
// identidades enquanto leituras derivam `dest` a partir dele.
func TestCorridaEntreUseIdentitiesEList(t *testing.T) {
	reg := NewRegistry([]Machine{
		{Name: "macmini", Host: "100.100.125.103", Port: 22, Identity: "vanessa", Source: SourceApp},
		{Name: "macbook", Host: "100.64.0.2", Port: 22, Identity: "vanessa", Source: SourceApp},
	})

	// Dois stores distintos, ambos válidos: o teste não quer ver qual dos dois
	// venceu, quer ver que ninguém leu o ponteiro no meio da troca.
	primeiro := NewIdentityStore()
	if _, err := primeiro.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add no primeiro store: %v", err)
	}
	segundo := NewIdentityStore()
	if _, err := segundo.Add(Identity{Name: "vanessa", Username: "outra"}, ""); err != nil {
		t.Fatalf("Add no segundo store: %v", err)
	}

	// Liga um store ANTES de soltar as goroutines. Sem isto o leitor pode rodar
	// antes do primeiro escritor e ver o registro sem store nenhum, onde `dest`
	// vazio é o comportamento correto — falha de teste, não do código.
	reg.UseIdentities(primeiro)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for n := 0; n < 200; n++ {
				if i%2 == 0 {
					reg.UseIdentities(primeiro)
				} else {
					reg.UseIdentities(segundo)
				}
			}
		}(i)
	}
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 200; n++ {
				// List e Get são os dois caminhos que chamam resolve.
				for _, m := range reg.List() {
					// `dest` tem que sair de UM dos dois usuários, nunca vazio e
					// nunca meio escrito.
					if m.Identity != "" && m.Dest == "" {
						t.Errorf("máquina %s com identidade e dest vazio", m.Name)
						return
					}
				}
				if m, ok := reg.Get("macmini"); ok && m.Dest == "" {
					t.Error("Get devolveu macmini com dest vazio")
					return
				}
			}
		}()
	}
	wg.Wait()
}

// TestCorridaEntreEscritaNoStoreELeituraNoRegistro cruza escrita no store com
// leitura derivada no registro: garante que a derivação de `dest` não enxerga
// identidade meio escrita.
func TestCorridaEntreEscritaNoStoreELeituraNoRegistro(t *testing.T) {
	idents := NewIdentityStore()
	if _, err := idents.Add(Identity{Name: "vanessa", Username: "vx"}, ""); err != nil {
		t.Fatalf("Add: %v", err)
	}
	reg := NewRegistry([]Machine{
		{Name: "macmini", Host: "100.100.125.103", Port: 22, Identity: "vanessa", Source: SourceApp},
	})
	reg.UseIdentities(idents)

	var wg sync.WaitGroup
	wg.Add(3)

	// Escreve no store.
	go func() {
		defer wg.Done()
		for n := 0; n < 300; n++ {
			if _, err := idents.Update("vanessa", "vx", nil); err != nil {
				t.Errorf("Update: %v", err)
				return
			}
		}
	}()
	// Lê pelo registro (passa por resolve → lock do store).
	go func() {
		defer wg.Done()
		for n := 0; n < 300; n++ {
			if m, ok := reg.Get("macmini"); ok && m.Dest != "vx@100.100.125.103" {
				t.Errorf("dest derivado errado: %q", m.Dest)
				return
			}
		}
	}()
	// Escreve no registro, para as duas travas se cruzarem de verdade.
	go func() {
		defer wg.Done()
		for n := 0; n < 300; n++ {
			if err := reg.SetTheme("macmini", "dracula"); err != nil {
				t.Errorf("SetTheme: %v", err)
				return
			}
		}
	}()

	wg.Wait()
}

// TestCorridaEmMaquinaDeEnvNaoDerivaNada: `source: env` não passa por identidade,
// e `dest` gravado é a verdade. Vale sob concorrência também — um resolve que
// resolvesse máquina de env sobrescreveria o destino do hub.env por vazio.
func TestCorridaEmMaquinaDeEnvNaoDerivaNada(t *testing.T) {
	reg := NewRegistry([]Machine{
		{Name: "macbook", Dest: "user@100.64.0.2", Port: 22, Source: SourceEnv},
	})
	idents := NewIdentityStore()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for n := 0; n < 300; n++ {
			reg.UseIdentities(idents)
		}
	}()
	go func() {
		defer wg.Done()
		for n := 0; n < 300; n++ {
			m, ok := reg.Get("macbook")
			if !ok {
				t.Error("macbook desapareceu")
				return
			}
			if m.Dest != "user@100.64.0.2" {
				t.Errorf("dest da máquina de env mudou: %q", m.Dest)
				return
			}
		}
	}()
	wg.Wait()
}
