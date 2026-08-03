package launcher

import (
	"slices"
	"sync"
	"testing"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
	"github.com/vxfontes/cutuque/hub/internal/machine"
)

func TestRegisterMachineFazAMaquinaVirarAlvo(t *testing.T) {
	l, _ := newTestLauncher(nil)
	if slices.Contains(l.Machines(), "vps") {
		t.Fatal("vps não devia existir antes do cadastro")
	}

	l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@1.2.3.4", Port: 22, Source: machine.SourceApp})

	if !slices.Contains(l.Machines(), "vps") {
		t.Errorf("vps não apareceu em Machines(): %v", l.Machines())
	}
	// Um alvo por agente: senão lançar codex numa máquina nova daria
	// ErrUnknownAgent, e a máquina pareceria meio quebrada.
	for _, kind := range []string{"claude-code", "codex", "opencode"} {
		if _, ok := l.target("vps", kind); !ok {
			t.Errorf("faltou o alvo de %s na máquina cadastrada", kind)
		}
	}
	if _, ok := l.anyTarget("vps"); !ok {
		t.Error("anyTarget não achou a máquina cadastrada")
	}
}

// Editar o destino no app tem que refletir no alvo: senão a máquina continuaria
// conectando no endereço antigo e a edição seria só cosmética na lista.
func TestRegisterMachineDeNovoTrocaOAlvo(t *testing.T) {
	l, _ := newTestLauncher(nil)
	l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@1.2.3.4", Port: 22, Source: machine.SourceApp})
	antes, _ := l.anyTarget("vps")
	l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@5.6.7.8", Port: 22, Source: machine.SourceApp})
	depois, _ := l.anyTarget("vps")

	if antes == depois {
		t.Error("o alvo continuou o mesmo depois de mudar o destino")
	}
	if got := len(l.Machines()); got != 1 {
		t.Errorf("cadastro repetido duplicou a máquina: %v", l.Machines())
	}
}

func TestUnregisterMachineTiraOAlvo(t *testing.T) {
	l, _ := newTestLauncher(nil)
	l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@1.2.3.4", Port: 22, Source: machine.SourceApp})
	l.UnregisterMachine("vps")

	if slices.Contains(l.Machines(), "vps") {
		t.Errorf("vps sobreviveu à remoção: %v", l.Machines())
	}
	if _, ok := l.anyTarget("vps"); ok {
		t.Error("anyTarget ainda resolve uma máquina removida")
	}
}

func TestUnregisterMachineDesconhecidaNaoMexeNoResto(t *testing.T) {
	l, _ := newTestLauncher(nil)
	l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@1.2.3.4", Port: 22, Source: machine.SourceApp})
	l.UnregisterMachine("nao-existe")

	if !slices.Contains(l.Machines(), "vps") {
		t.Errorf("remover uma máquina inexistente levou outra junto: %v", l.Machines())
	}
}

// O mapa de alvos era documentado como imutável e lido sem lock em cinco
// lugares. Agora que o cadastro escreve nele em runtime, o -race é quem prova
// que a substituição sob RWMutex não briga com as leituras em voo.
func TestCadastroEmRuntimeNaoCorreComAsLeituras(t *testing.T) {
	l, _ := newTestLauncher(nil)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			l.RegisterMachine(machine.Machine{Name: "vps", Dest: "root@1.2.3.4", Port: 22})
		}()
		go func() { defer wg.Done(); _ = l.Machines(); _, _ = l.anyTarget("vps") }()
	}
	wg.Wait()
}

// TargetsFor é o construtor compartilhado pelo boot (hub.env) e pelo cadastro
// em runtime: os dois têm que sair com os três agentes e o nome/destino certos.
// Que a identidade chega até a linha de ssh é assunto do adapter — está coberto
// em claudecode/target_test.go.
func TestTargetsForMontaOsTresAgentes(t *testing.T) {
	tgts := TargetsFor(machine.Machine{
		Name: "vps", Dest: "root@1.2.3.4", Port: 2222,
		Source: machine.SourceApp, KeyPath: "/data/machines/keys/vps",
	}, "/data/machines/known_hosts")

	for _, kind := range []string{"claude-code", "codex", "opencode"} {
		tgt, ok := tgts[kind]
		if !ok {
			t.Fatalf("faltou o alvo de %s: %v", kind, chaves(tgts))
		}
		if tgt.Name() != "vps" {
			t.Errorf("%s: nome do alvo = %q, quero %q", kind, tgt.Name(), "vps")
		}
	}
}

func chaves(m map[string]claudecode.Target) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}
