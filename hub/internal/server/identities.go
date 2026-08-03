package server

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// As identidades são o objeto que faltava para o cadastro parecer com o do
// Termius: um conjunto (usuário remoto + chave + senha opcional) reutilizável
// entre máquinas. Cadastrar cinco hosts da mesma conta passa a ser escolher a
// mesma identidade cinco vezes, com UMA chave instalada.
//
// O que estas rotas nunca fazem: devolver senha. O corpo da identidade carrega
// has_password (existe ou não), e é tudo. A única leitora do segredo é a
// instalação da chave, dentro do hub.

// Identities é o store de identidades visto pelo servidor. Interface para o teste
// não precisar de /data nem de chave de cifra.
//
// Embute MachineIdentities (Get/Password/SetKeyPath) porque é o MESMO store que o
// cadastro de máquinas usa para instalar a chave. Vale registrar o limite: nenhum
// dos handlers DESTE arquivo chama Password — a única chamadora do segredo em todo
// o hub é a instalação da chave, em machines_admin.go, e de lá ele vai para a
// conexão ssh, não para a resposta.
type Identities interface {
	MachineIdentities
	List() []machine.Identity
	Add(id machine.Identity, password string) (machine.Identity, error)
	Update(name, username string, password *string) (machine.Identity, error)
	Remove(name string, inUse func(string) bool) error
	CanStorePassword() bool
}

// maxIdentityBody: nome, usuário e senha são pequenos.
const maxIdentityBody = 8 << 10

// identityListResp lista as identidades e diz se o hub sabe guardar senha —
// sem CUTUQUE_IDENTITY_KEY ele recusa, e o app não deve oferecer o campo para
// depois tomar um 400.
type identityListResp struct {
	Identities       []machine.Identity `json:"identities"`
	CanStorePassword bool               `json:"can_store_password"`
}

// identityCreateReq é o corpo do POST /identities: os três campos da tela "new
// identity" do Termius. Senha vazia = identidade só de chave.
type identityCreateReq struct {
	Name     string `json:"name"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// identityResp devolve a identidade e, na criação, a chave PÚBLICA recém-gerada
// — é o que a usuária instala no destino quando não quer passar a senha ao hub.
type identityResp struct {
	Identity  machine.Identity `json:"identity"`
	PublicKey string           `json:"public_key,omitempty"`
}

// identityPatchReq é o corpo do PATCH. Password é ponteiro de propósito, e a
// diferença importa:
//
//	campo ausente (ou null) → nil    → mantém a senha guardada
//	""                      → limpa  → apaga a senha guardada
//	texto                   → troca
//
// Com string comum, um app que mandasse só {"username":"..."} apagaria a senha
// sem pedir. Segredo não se perde por omissão.
type identityPatchReq struct {
	Username string  `json:"username"`
	Password *string `json:"password"`
}

// IdentitiesHandler lista as identidades cadastradas.
//
//	GET /identities → 200 {"identities":[...],"can_store_password":bool}
func IdentitiesHandler(idents Identities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		lista := idents.List()
		if lista == nil {
			lista = []machine.Identity{} // "[]" e não "null": o app decodifica array
		}
		writeJSONResp(w, http.StatusOK, identityListResp{
			Identities:       lista,
			CanStorePassword: idents.CanStorePassword(),
		})
	}
}

// IdentityCreateHandler cadastra uma identidade e gera o par de chaves dela.
//
// A chave nasce junto de propósito: uma identidade sem chave só serviria para
// digitar senha em toda conexão, que é exatamente o que o Cutuque existe para
// não fazer. A pública volta na resposta; a privada fica em /data.
//
// Se a chave falhar, a identidade é desfeita: melhor não existir do que existir
// pela metade e falhar no primeiro cadastro de máquina.
//
//	POST /identities {"name","username","password"}
//	→ 201 {"identity","public_key"} | 400 | 409 | 500
func IdentityCreateHandler(idents Identities, keys IdentityKeys) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxIdentityBody)
		var req identityCreateReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}

		id, err := idents.Add(machine.Identity{Name: req.Name, Username: req.Username}, req.Password)
		switch {
		case errors.Is(err, machine.ErrDuplicateIdentity):
			writeJSONError(w, http.StatusConflict, "duplicate_identity")
			return
		case errors.Is(err, machine.ErrInvalidName), errors.Is(err, machine.ErrInvalidUsername):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_identity", err.Error())
			return
		case errors.Is(err, machine.ErrNoSecretKey):
			// Pediram para guardar senha num hub que não sabe cifrar. Recusar é o
			// desenho: gravar em claro seria pior.
			writeJSONErrorDetail(w, http.StatusBadRequest, "cannot_store_password", err.Error())
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}

		pub, err := keys.Generate(id.Name)
		if err != nil {
			_ = idents.Remove(id.Name, nil)
			writeJSONErrorDetail(w, http.StatusInternalServerError, "keygen_failed", err.Error())
			return
		}
		path, err := keys.KeyPath(id.Name)
		if err == nil {
			err = idents.SetKeyPath(id.Name, path)
		}
		if err != nil {
			_ = keys.RemoveKey(id.Name)
			_ = idents.Remove(id.Name, nil)
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
			return
		}
		atual, _ := idents.Get(id.Name)
		writeJSONResp(w, http.StatusCreated, identityResp{Identity: atual, PublicKey: pub})
	}
}

// IdentityPatchHandler altera o usuário e/ou a senha de uma identidade.
//
// Trocar o usuário muda o destino de TODAS as máquinas que usam a identidade —
// é o efeito desejado (é para isso que ela é compartilhada), mas vale dizer: a
// chave do Cutuque pode não estar na authorized_keys da conta nova, e aí aquelas
// máquinas param de conectar até a chave ser instalada de novo.
//
//	PATCH /identities/{identity} {"username","password"}
//	→ 200 {"identity"} | 400 | 404 | 500
func IdentityPatchHandler(idents Identities) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxIdentityBody)
		var req identityPatchReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		id, err := idents.Update(r.PathValue("identity"), req.Username, req.Password)
		switch {
		case errors.Is(err, machine.ErrIdentityNotFound):
			writeJSONError(w, http.StatusNotFound, "unknown_identity")
		case errors.Is(err, machine.ErrInvalidUsername):
			writeJSONErrorDetail(w, http.StatusBadRequest, "invalid_identity", err.Error())
		case errors.Is(err, machine.ErrNoSecretKey):
			writeJSONErrorDetail(w, http.StatusBadRequest, "cannot_store_password", err.Error())
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "register_failed")
		default:
			writeJSONResp(w, http.StatusOK, identityResp{Identity: id})
		}
	}
}

// IdentityDeleteHandler apaga a identidade e a chave dela.
//
// Recusa (409) enquanto alguma máquina a usar: sem isso a máquina viraria um host
// sem conta nem chave, e o erro apareceria longe da causa — numa conexão qualquer,
// dias depois. Quem responde "está em uso?" é o registro de máquinas, passado como
// callback: o store de identidades não conhece máquinas, e não deveria.
//
// A pública instalada nos hosts NÃO é removida de lá (isso exigiria entrar em cada
// um). Ela deixa de ter privada correspondente, então não abre mais nada — mas
// continua listada na authorized_keys de quem quiser limpar na mão.
//
//	DELETE /identities/{identity} → 204 | 404 | 409 in_use | 500
func IdentityDeleteHandler(idents Identities, keys IdentityKeys, reg *machine.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("identity")
		emUso := func(string) bool { return false }
		if reg != nil {
			emUso = reg.UsesIdentity
		}
		if err := idents.Remove(name, emUso); err != nil {
			switch {
			case errors.Is(err, machine.ErrIdentityNotFound):
				writeJSONError(w, http.StatusNotFound, "unknown_identity")
			case errors.Is(err, machine.ErrIdentityInUse):
				writeJSONErrorDetail(w, http.StatusConflict, "identity_in_use", err.Error())
			default:
				writeJSONError(w, http.StatusInternalServerError, "delete_failed")
			}
			return
		}
		// A chave sai depois: se apagá-la falhar, a identidade já saiu e o par fica
		// órfão em /data — ruim, mas inofensivo. Na ordem inversa, um erro no
		// registro deixaria identidade viva com a chave apagada, ou seja, uma
		// identidade que não entra em lugar nenhum.
		_ = keys.RemoveKey(name)
		w.WriteHeader(http.StatusNoContent)
	}
}
