package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// MachineKeys é tudo que o cadastro de máquina precisa do KeyStore. Interface
// (e não o *machine.KeyStore direto) para o teste poder trocar por um fake: o
// de verdade roda ssh-keygen, ssh-keyscan e abre conexão ssh.
type MachineKeys interface {
	// Generate cria o par da máquina e devolve a PÚBLICA.
	Generate(name string) (string, error)
	// KeyPath é onde ficou a privada — vai para o registro, nunca para o app.
	KeyPath(name string) (string, error)
	// PublicKey relê a pública de um cadastro que já existe.
	PublicKey(name string) (string, error)
	RemoveKey(name string) error
	// Scan lê as chaves do host sem gravar nada: é o passo de conferência.
	Scan(ctx context.Context, dest string, port int) (lines, fingerprint string, err error)
	// Trust grava no known_hosts o que a usuária confirmou.
	Trust(lines string) error
	// InstallKey põe a pública na authorized_keys do destino usando a senha
	// que a usuária digitou (uso único, só em memória).
	InstallKey(ctx context.Context, dest string, port int, password, pub, expectedFingerprint string) error
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

// machineCreateReq é o corpo do POST /machines. Nem chave nem fingerprint vêm
// do app: os dois são do hub, e aceitá-los aqui deixaria o app apontar o
// cadastro para um host que ninguém conferiu.
type machineCreateReq struct {
	Name string `json:"name"`
	Dest string `json:"dest"`
	Port int    `json:"port"`
}

// machineCreateResp devolve o cadastro, a chave PÚBLICA (para a usuária instalar
// no destino) e a impressão digital do host para ela conferir. O fingerprint vem
// solto, fora da máquina, justamente porque ainda NÃO está confiado — quem
// confia é o POST /trust.
type machineCreateResp struct {
	Machine     machine.Machine `json:"machine"`
	PublicKey   string          `json:"public_key"`
	Fingerprint string          `json:"fingerprint"`
}

type machineTrustReq struct {
	Fingerprint string `json:"fingerprint"`
}

type machineInstallReq struct {
	Password string `json:"password"`
}

type machinePatchReq struct {
	Dest string `json:"dest"`
	Port int    `json:"port"`
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

// MachineCreateHandler cadastra uma máquina nova: valida, gera o par de chaves e
// escaneia o host para a usuária conferir a impressão digital. Nada é confiado
// aqui — o cadastro nasce sem fingerprint, e só o POST /trust o grava.
//
//	POST /machines {"name","dest","port"}
//	→ 201 {"machine","public_key","fingerprint"} | 400 | 409 | 500 | 502
func MachineCreateHandler(reg *machine.Registry, keys MachineKeys) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineCreateReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}

		m, err := reg.Add(machine.Machine{Name: req.Name, Dest: req.Dest, Port: req.Port})
		switch {
		case errors.Is(err, machine.ErrDuplicateName):
			writeJSONError(w, http.StatusConflict, "duplicate_name")
			return
		case errors.Is(err, machine.ErrInvalidName), errors.Is(err, machine.ErrInvalidDest):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_machine", err.Error())
			return
		case err != nil:
			// Sobrou só o persist: o /data não aceitou a escrita.
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}

		pub, err := keys.Generate(m.Name)
		if err != nil {
			desfazCadastro(reg, keys, m.Name)
			writeJSONErrorDetail(w, http.StatusInternalServerError, "keygen_failed", err.Error())
			return
		}
		path, err := keys.KeyPath(m.Name)
		if err == nil {
			err = reg.SetKeyPath(m.Name, path)
		}
		if err != nil {
			desfazCadastro(reg, keys, m.Name)
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
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
			desfazCadastro(reg, keys, m.Name)
			writeJSONErrorDetail(w, http.StatusBadGateway, "scan_failed", err.Error())
			return
		}

		writeJSONResp(w, http.StatusCreated, machineCreateResp{Machine: m, PublicKey: pub, Fingerprint: fp})
	}
}

// desfazCadastro tira o que o POST /machines já criou quando um passo seguinte
// falha. Melhor esforço: o erro que interessa é o original, não o da limpeza.
func desfazCadastro(reg *machine.Registry, keys MachineKeys, name string) {
	_ = keys.RemoveKey(name)
	_ = reg.Remove(name)
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

// MachineInstallKeyHandler instala a chave pública do Cutuque no destino,
// autenticando uma vez com a senha que a usuária digitou. A senha é de uso
// único: vive no corpo do request e na memória do processo, e não é gravada,
// registrada em log nem devolvida.
//
//	POST /machines/{machine}/install-key {"password"}
//	→ 200 {"ok":true} | 400 | 403 | 404 | 409 not_trusted | 500 | 502
func MachineInstallKeyHandler(reg *machine.Registry, keys MachineKeys) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machineInstallReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Password == "" {
			// Senha vazia não autentica em lugar nenhum: recusa antes da rede.
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
		pub, err := keys.PublicKey(m.Name)
		if err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "no_key", err.Error())
			return
		}
		if err := keys.InstallKey(r.Context(), m.Dest, m.Port, req.Password, pub, m.HostFingerprint); err != nil {
			writeJSONErrorDetail(w, http.StatusBadGateway, "install_failed", err.Error())
			return
		}
		writeOK(w)
	}
}

// MachinePatchHandler altera destino e porta de uma máquina cadastrada pelo app.
// Nome, chave e fingerprint não se mexem por aqui (o registro cuida disso:
// mudar o destino derruba a confirmação do host).
//
// Mudar o destino derruba a confirmação, e com ela o alvo: a máquina volta a
// ser desconhecida até a usuária conferir a impressão do endereço novo.
//
//	PATCH /machines/{machine} {"dest","port"}
//	→ 200 {"machine"} | 400 | 403 | 404 | 500
func MachinePatchHandler(reg *machine.Registry, targets MachineTargets) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxMachineBody)
		var req machinePatchReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		m, err := reg.Update(r.PathValue("machine"), machine.Machine{Dest: req.Dest, Port: req.Port})
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

// MachineDeleteHandler descadastra uma máquina do app e apaga a chave privada
// dela.
//
// A chave sai primeiro: se o disco recusar, nada foi alterado e a usuária pode
// tentar de novo. Na ordem inversa, uma falha deixaria a privada órfã em /data
// sem cadastro que a explicasse.
//
// A entrada no known_hosts fica: ela só diz "este host tem esta chave", e
// mantê-la faz recadastrar a mesma máquina simplesmente funcionar.
//
//	DELETE /machines/{machine} → 204 | 403 | 404 | 500
func MachineDeleteHandler(reg *machine.Registry, keys MachineKeys, targets MachineTargets) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		m, ok := maquinaEditavel(w, reg, r.PathValue("machine"))
		if !ok {
			return
		}
		if err := keys.RemoveKey(m.Name); err != nil {
			writeJSONErrorDetail(w, http.StatusInternalServerError, "delete_failed", err.Error())
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
