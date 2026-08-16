package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// IdentityKeys é a parte do cofre que pertence à IDENTIDADE: um par de chaves
// por conta remota, reusado por todas as máquinas que a usam. Chaveada pelo nome
// da identidade — nunca pelo da máquina.
type IdentityKeys interface {
	// Generate cria o par da identidade e devolve a PÚBLICA.
	Generate(identity string) (string, error)
	// KeyPath é onde ficou a privada — vai para a identidade, nunca para o app.
	KeyPath(identity string) (string, error)
	// PublicKey relê a pública de uma identidade que já existe.
	PublicKey(identity string) (string, error)
	RemoveKey(identity string) error
}

// HostKeys é a parte do cofre que pertence ao HOST: o TOFU e a instalação da
// chave no destino.
type HostKeys interface {
	// Scan lê as chaves do host sem gravar nada: é o passo de conferência.
	Scan(ctx context.Context, dest string, port int) (lines, fingerprint string, err error)
	// Trust grava no known_hosts o que a usuária confirmou.
	Trust(lines string) error
	// InstallKey põe a pública na authorized_keys do destino usando a senha —
	// digitada agora ou guardada na identidade. Uso único, só em memória.
	InstallKey(ctx context.Context, dest string, port int, password, pub, expectedFingerprint string) error
	// DetectOS conecta com a chave já instalada e devolve o sistema do host. É
	// também a prova de que a instalação funcionou.
	DetectOS(ctx context.Context, dest string, port int, keyPath, expectedFingerprint string) (string, error)
}

// MachineKeys é o cofre inteiro (o *machine.KeyStore). Interface, e não o tipo
// direto, para o teste poder trocar por um fake: o de verdade roda ssh-keygen,
// ssh-keyscan e abre conexão ssh.
type MachineKeys interface {
	IdentityKeys
	HostKeys
}

// MachineIdentities é o store de identidades visto pelo cadastro de máquinas: só
// o suficiente para conferir se a identidade existe, para pegar a senha guardada
// na hora de instalar a chave e para anotar a chave de uma identidade que ainda
// não tem (o caso das migradas). A senha lida aqui não vira resposta HTTP em
// nenhum caminho.
type MachineIdentities interface {
	Get(name string) (machine.Identity, bool)
	Password(name string) (string, error)
	SetKeyPath(name, path string) error
}

// MachineTargets é o Launcher visto pelo cadastro: quem faz a máquina virar
// alvo de verdade (lançar sessão, listar pasta, abrir arquivo). Interface para o
// server não depender do launcher — e para o teste conferir o que foi
// registrado sem subir um Launcher inteiro.
type MachineTargets interface {
	RegisterMachine(m machine.Machine)
	UnregisterMachine(name string)
}

// sincronizaAlvo aplica a única regra que governa o mapa de alvos: a máquina é
// alvo se, e só se, tem impressão digital confirmada. Sem fingerprint o hub se
// recusa a conectar de qualquer jeito — deixá-la como alvo só trocaria um
// "máquina desconhecida" honesto por um erro de ssh no meio do lançamento.
//
// nil é aceito de propósito: sem CUTUQUE_MACHINES_DIR o cadastro nem existe, e
// o hub roda só com as máquinas do hub.env.
func sincronizaAlvo(targets MachineTargets, m machine.Machine) {
	if targets == nil {
		return
	}
	if m.HostFingerprint == "" {
		targets.UnregisterMachine(m.Name)
		return
	}
	targets.RegisterMachine(m)
}

// maxMachineBody: nome, destino e senha são pequenos. Teto baixo para o corpo
// não virar vetor de memória.
const maxMachineBody = 8 << 10

// machineCreateReq é o corpo do POST /machines. Depois do redesenho o app manda
// o HOST puro e o nome de uma IDENTIDADE — nunca "user@host": a conta remota mora
// na identidade, e aceitar dest aqui deixaria o app escolher usuário por fora.
//
// Nem chave nem fingerprint vêm do app: os dois são do hub, e aceitá-los deixaria
// o app apontar o cadastro para um host que ninguém conferiu.
type machineCreateReq struct {
	Name     string `json:"name"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Identity string `json:"identity"`
	Theme    string `json:"theme"`
}

// machineCreateResp devolve o cadastro, a chave PÚBLICA da identidade (para a
// usuária instalar no destino) e a impressão digital do host para ela conferir. O
// fingerprint vem solto, fora da máquina, justamente porque ainda NÃO está
// confiado — quem confia é o POST /trust.
type machineCreateResp struct {
	Machine     machine.Machine `json:"machine"`
	PublicKey   string          `json:"public_key"`
	Fingerprint string          `json:"fingerprint"`
}

type machineTrustReq struct {
	Fingerprint string `json:"fingerprint"`
}

// machineInstallReq: senha vazia significa "usa a que está guardada na
// identidade". O app manda senha aqui só quando a identidade não guardou nenhuma.
type machineInstallReq struct {
	Password string `json:"password"`
}

type machinePatchReq struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Identity string `json:"identity"`
	Theme    string `json:"theme"`
}

// machineAppearanceReq é o corpo do PUT de aparência. PUT e não PATCH porque a
// semântica é de substituição: campo vazio é uma ESCOLHA (tema Padrão, ícone
// automático), não uma omissão. Sem isso não haveria como voltar atrás, já que o
// id do tema Padrão é a string vazia.
type machineAppearanceReq struct {
	Theme string `json:"theme"`
	Icon  string `json:"icon"`
}

// machineResp é o corpo de sucesso do PATCH e do trust.
type machineResp struct {
	Machine machine.Machine `json:"machine"`
}

// writeJSONErrorDetail responde {"error": code, "detail": "..."}. Variante do
// writeJSONError para quando só o código não basta: no cadastro, a diferença
// entre "o host não respondeu" e "a chave do host mudou" é exatamente o que a
// usuária precisa ler. Nenhum detalhe daqui carrega senha — o install.go
// embrulha os erros sem ela.
func writeJSONErrorDetail(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "detail": detail})
}

// MachineCreateHandler cadastra uma máquina nova: valida, confere a identidade e
// escaneia o host para a usuária conferir a impressão digital. Nada é confiado
// aqui — o cadastro nasce sem fingerprint, e só o POST /trust o grava.
//
// A chave NÃO é gerada aqui: ela é da identidade, e nasceu com ela. Só há uma
// exceção — identidade sem chave (criada antes do redesenho, ou vinda da
// migração), que ganha o par agora.
//
//	POST /machines {"name","host","port","identity","theme"}
//	→ 201 {"machine","public_key","fingerprint"} | 400 | 409 | 500 | 502
func MachineCreateHandler(reg *machine.Registry, keys MachineKeys, idents MachineIdentities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineCreateReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		// Confere a identidade ANTES de cadastrar: uma máquina apontando para
		// identidade inexistente não tem usuário nem chave, e falharia depois com
		// um erro de ssh que não explica a causa.
		id, ok := idents.Get(strings.TrimSpace(req.Identity))
		if !ok {
			writeJSONErrorDetail(w, http.StatusBadRequest, "unknown_identity",
				"não existe identidade chamada "+req.Identity)
			return
		}
		if err := garanteChave(keys, idents, id); err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "keygen_failed", err.Error())
			return
		}

		m, err := reg.Add(machine.Machine{
			Name: req.Name, Host: req.Host, Port: req.Port,
			Identity: req.Identity, Theme: req.Theme,
		})
		switch {
		case errors.Is(err, machine.ErrDuplicateName):
			writeJSONError(w, http.StatusConflict, "duplicate_name")
			return
		case errors.Is(err, machine.ErrDuplicateHost):
			// Detalhe junto: sem ele o app só diria "já existe", e a máquina
			// repetida costuma estar cadastrada com OUTRO nome — que é
			// justamente o que a usuária precisa saber para achá-la.
			writeJSONErrorDetail(w, http.StatusConflict, "duplicate_host", err.Error())
			return
		case errors.Is(err, machine.ErrInvalidName), errors.Is(err, machine.ErrInvalidDest):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_machine", err.Error())
			return
		case err != nil:
			// Sobrou só o persist: o /data não aceitou a escrita.
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}

		pub, err := keys.PublicKey(m.Identity)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "no_key", err.Error())
			desfazCadastro(reg, m.Name)
			return
		}

		// As linhas do keyscan são descartadas de propósito: o /trust escaneia
		// de novo na hora de confirmar. Guardá-las aqui seria confiar num
		// retrato tirado antes de a usuária olhar.
		_, fp, err := keys.Scan(r.Context(), m.Dest, m.Port)
		if err != nil {
			// Cadastro sem fingerprint é cadastro inútil: o hub se recusa a
			// conectar. Desfazer evita deixar lixo que ela teria que apagar na
			// mão antes de tentar de novo.
			desfazCadastro(reg, m.Name)
			writeJSONErrorDetail(w, http.StatusBadGateway, "scan_failed", err.Error())
			return
		}

		writeJSONResp(w, http.StatusCreated, machineCreateResp{Machine: m, PublicKey: pub, Fingerprint: fp})
	}
}

// desfazCadastro tira o que o POST /machines já criou quando um passo seguinte
// falha. Melhor esforço: o erro que interessa é o original, não o da limpeza.
//
// NÃO mexe na chave: ela é da identidade e pode estar em uso por outras máquinas.
// Apagá-la aqui derrubaria o acesso a hosts que nada têm a ver com este cadastro.
func desfazCadastro(reg *machine.Registry, name string) {
	_ = reg.Remove(name)
}

// garanteChave cria o par da identidade quando ela ainda não tem. Nada a fazer no
// caso comum (a identidade nasce com chave no POST /identities); existe para as
// migradas do formato antigo cuja máquina não tinha chave gerada, que de outro
// modo ficariam sem jeito de ganhar uma.
//
// Gerar em cima de uma chave existente seria destrutivo — a pública antiga já está
// nas authorized_keys dos hosts —, por isso o guarda do KeyPath vazio.
func garanteChave(keys IdentityKeys, idents MachineIdentities, id machine.Identity) error {
	if id.KeyPath != "" {
		return nil
	}
	if _, err := keys.Generate(id.Name); err != nil {
		return err
	}
	path, err := keys.KeyPath(id.Name)
	if err != nil {
		return err
	}
	return idents.SetKeyPath(id.Name, path)
}

// MachineTrustHandler confirma a impressão digital do host (TOFU) e grava a
// chave dele no known_hosts do Cutuque.
//
// O hub escaneia DE NOVO e compara com o que a usuária confirmou. É o ponto do
// fluxo em que um host trocado é pego: sem essa segunda leitura, bastaria
// responder o cadastro e trocar a chave depois.
//
// Confirmada a impressão, a máquina vira alvo: é neste ponto (e só neste) que
// ela passa a ser conectável.
//
//	POST /machines/{machine}/trust {"fingerprint"}
//	→ 200 {"machine"} | 400 | 403 | 404 | 409 | 500 | 502
func MachineTrustHandler(reg *machine.Registry, keys MachineKeys, targets MachineTargets) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineTrustReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Fingerprint == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}

		lines, fp, err := keys.Scan(r.Context(), m.Dest, m.Port)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusBadGateway, "scan_failed", err.Error())
			return
		}
		if fp != req.Fingerprint {
			writeJSONErrorDetail(w, http.StatusConflict, "fingerprint_mismatch",
				"a máquina respondeu com "+fp+", e você confirmou "+req.Fingerprint)
			return
		}
		if err := keys.Trust(lines); err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "trust_failed", err.Error())
			return
		}
		if err := reg.SetFingerprint(m.Name, fp); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}
		atual, _ := reg.Get(m.Name)
		sincronizaAlvo(targets, atual)
		writeJSONResp(w, http.StatusOK, machineResp{Machine: atual})
	}
}

// machineScanResp devolve a impressão digital que o host está apresentando
// AGORA. Fora de uma máquina, como no cadastro: nada aqui está confiado.
type machineScanResp struct {
	Fingerprint string `json:"fingerprint"`
}

// MachineScanHandler relê a impressão digital do host de um cadastro que já
// existe, para a usuária conferir.
//
// Existe porque o fingerprint do POST /machines vive só na resposta: quem fechar
// o app no meio do cadastro ficaria com uma máquina pendente e sem nenhum jeito
// de confirmá-la. Não grava nada — confiar continua sendo só do /trust, que
// escaneia de novo por conta própria.
//
//	GET /machines/{machine}/scan → 200 {"fingerprint"} | 403 | 404 | 502
func MachineScanHandler(reg *machine.Registry, keys MachineKeys) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}
		_, fp, err := keys.Scan(r.Context(), m.Dest, m.Port)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusBadGateway, "scan_failed", err.Error())
			return
		}
		writeJSONResp(w, http.StatusOK, machineScanResp{Fingerprint: fp})
	}
}

// MachineInstallKeyHandler instala a chave pública da identidade no destino,
// autenticando uma vez com a senha da conta remota.
//
// A senha vem de um dos dois lugares, nesta ordem: a que a usuária acabou de
// digitar (corpo do request, uso único, nunca gravada) ou a guardada na
// identidade — cifrada em /data, decifrada aqui dentro e usada na hora. Nos dois
// casos ela não é logada, nem devolvida, nem vai para linha de comando.
//
//	POST /machines/{machine}/install-key {"password"}   (password vazia = a guardada)
//	→ 200 {"ok":true} | 400 | 403 | 404 | 409 not_trusted | 500 | 502
func MachineInstallKeyHandler(reg *machine.Registry, keys MachineKeys, idents MachineIdentities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineInstallReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}
		// Sem TOFU confirmado a senha não sai daqui: mandá-la a um host que
		// ninguém conferiu é entregá-la a quem estiver no meio.
		if m.HostFingerprint == "" {
			writeJSONErrorDetail(w, http.StatusConflict, "not_trusted",
				"confirme a impressão digital de "+m.Name+" antes de instalar a chave")
			return
		}
		senha := req.Password
		if senha == "" {
			guardada, err := idents.Password(m.Identity)
			if err != nil {
				// Sem senha nenhuma não há o que tentar: o app precisa pedir uma.
				writeJSONErrorDetail(w, http.StatusBadRequest, "no_password", err.Error())
				return
			}
			senha = guardada
		}
		pub, err := keys.PublicKey(m.Identity)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "no_key", err.Error())
			return
		}
		if err := keys.InstallKey(r.Context(), m.Dest, m.Port, senha, pub, m.HostFingerprint); err != nil {
			writeJSONErrorDetail(w, http.StatusBadGateway, "install_failed", err.Error())
			return
		}
		writeOK(w)
	}
}

// MachineDetectOSHandler conecta com a chave já instalada e grava o sistema que o
// host respondeu — é o que faz o app mostrar a maçã no MacBook.
//
// Roda depois do install-key de propósito: usa a chave, não a senha. Assim o
// mesmo passo que descobre o SO prova que a instalação funcionou.
//
//	POST /machines/{machine}/detect-os → 200 {"machine"} | 403 | 404 | 409 | 500 | 502
func MachineDetectOSHandler(reg *machine.Registry, keys MachineKeys, idents MachineIdentities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}
		if m.HostFingerprint == "" {
			writeJSONErrorDetail(w, http.StatusConflict, "not_trusted",
				"confirme a impressão digital de "+m.Name+" antes de conectar")
			return
		}
		id, found := idents.Get(m.Identity)
		if !found {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "unknown_identity",
				"a máquina aponta para a identidade "+m.Identity+", que não existe")
			return
		}
		os, err := keys.DetectOS(r.Context(), m.Dest, m.Port, id.KeyPath, m.HostFingerprint)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusBadGateway, "detect_failed", err.Error())
			return
		}
		if err := reg.SetOS(m.Name, os); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}
		atual, _ := reg.Get(m.Name)
		writeJSONResp(w, http.StatusOK, machineResp{Machine: atual})
	}
}

// MachineAppearanceHandler troca o tema do terminal e o ícone de uma máquina já
// cadastrada. Rota separada do PATCH por dois motivos, e os dois importam:
//
//   - semântica: aqui vazio significa "volta ao padrão", enquanto no PATCH
//     significa "mantém o que está". Misturar as duas num campo só faria o tema
//     Padrão (id "") ser impossível de escolher de volta.
//   - segurança: aparência não afeta conexão, e esta rota por construção não tem
//     como mexer em host, porta, identidade ou fingerprint. Trocar de cor nunca
//     vai derrubar uma confiança que a usuária conferiu à mão.
//
// Não mexe no `os` detectado: o ícone manual é escolha, o SO é fato, e guardar os
// dois é o que permite voltar ao automático depois.
//
//	PUT /machines/{machine}/appearance {"theme","icon"}
//	→ 200 {"machine"} | 400 | 403 | 404 | 500
func MachineAppearanceHandler(reg *machine.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineAppearanceReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		m, err := reg.SetAppearance(r.PathValue("machine"), req.Theme, req.Icon)
		switch {
		case errors.Is(err, machine.ErrNotFound):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		// ErrReadOnly não é mais possível aqui desde 2026-08-16: SetAppearance
		// deixou de gatear por Editable() (aparência é do app, conexão é da
		// fonte — vale para env/local/app). Removido para não deixar um branch
		// morto e enganoso; ver hub/internal/machine/machine.go SetAppearance.
		case errors.Is(err, machine.ErrInvalidLook):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_appearance", err.Error())
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
		default:
			// Sem sincronizaAlvo: nada aqui muda o destino ssh.
			writeJSONResp(w, http.StatusOK, machineResp{Machine: m})
		}
	}
}

// MachinePatchHandler altera host, porta, identidade e tema de uma máquina
// cadastrada pelo app. Nome, chave e fingerprint não se mexem por aqui (o
// registro cuida disso).
//
// Mudar o host ou a porta derruba a confirmação, e com ela o alvo: a máquina volta
// a ser desconhecida até a usuária conferir a impressão do endereço novo. Trocar de
// IDENTIDADE não derruba — o fingerprint é do host, e quem entra nele é assunto
// separado.
//
//	PATCH /machines/{machine} {"host","port","identity","theme"}
//	→ 200 {"machine"} | 400 | 403 | 404 | 500
func MachinePatchHandler(reg *machine.Registry, targets MachineTargets, idents MachineIdentities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machinePatchReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		// Identidade só é conferida quando vem no patch: vazia significa "mantém a
		// atual", e a atual já foi conferida quando entrou.
		if novo := strings.TrimSpace(req.Identity); novo != "" {
			if _, ok := idents.Get(novo); !ok {
				writeJSONErrorDetail(w, http.StatusBadRequest, "unknown_identity",
					"não existe identidade chamada "+novo)
				return
			}
		}
		m, err := reg.Update(r.PathValue("machine"), machine.Machine{
			Host: req.Host, Port: req.Port, Identity: req.Identity, Theme: req.Theme,
		})
		switch {
		case errors.Is(err, machine.ErrNotFound):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case errors.Is(err, machine.ErrReadOnly):
			writeJSONError(w, http.StatusForbidden, "read_only")
		case errors.Is(err, machine.ErrInvalidName), errors.Is(err, machine.ErrInvalidDest):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_machine", err.Error())
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
		default:
			sincronizaAlvo(targets, m)
			writeJSONResp(w, http.StatusOK, machineResp{Machine: m})
		}
	}
}

// MachineDeleteHandler descadastra uma máquina do app.
//
// A chave NÃO é apagada: ela é da identidade, e outras máquinas podem estar
// usando a mesma. Quem apaga chave é o DELETE /identities/{identity}, que só
// aceita quando nenhuma máquina a referencia.
//
// A entrada no known_hosts fica: ela só diz "este host tem esta chave", e
// mantê-la faz recadastrar a mesma máquina simplesmente funcionar.
//
//	DELETE /machines/{machine} → 204 | 403 | 404 | 500
func MachineDeleteHandler(reg *machine.Registry, targets MachineTargets) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}
		if err := reg.Remove(m.Name); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "delete_failed")
			return
		}
		if targets != nil {
			targets.UnregisterMachine(m.Name)
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// maquinaEditavel busca a máquina e garante que ela é do app. Já responde o erro
// quando não é — o chamador só precisa devolver.
func maquinaEditavel(w http.ResponseWriter, reg *machine.Registry, name string) (machine.Machine, bool) {
	m, found := reg.Get(name)
	if !found {
		writeJSONError(w, http.StatusNotFound, "unknown_machine")
		return machine.Machine{}, false
	}
	if !m.Editable() {
		// Máquina do hub.env (ou a local): quem manda nela é o hub.env, com o
		// ~/.ssh do próprio hub. O app não mexe.
		writeJSONError(w, http.StatusForbidden, "read_only")
		return machine.Machine{}, false
	}
	return m, true
}
