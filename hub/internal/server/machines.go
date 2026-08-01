package server

import (
	"errors"
	"net/http"

	"github.com/vxfontes/cutuque/hub/internal/launcher"
	"github.com/vxfontes/cutuque/hub/internal/machine"
)

// MachinesHandler lista as máquinas que o hub conhece, como recurso rico (nome,
// destino, porta, origem) — diferente de GET /targets, que devolve só os nomes
// e continua servindo o fluxo de criar sessão.
//
//	GET /machines → 200 {"machines":[{name,dest,port,source}]}
func MachinesHandler(reg *machine.Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		list := reg.List()
		if list == nil {
			// Lista vazia, nunca null: o app decodifica [Machine].
			list = []machine.Machine{}
		}
		writeJSONResp(w, http.StatusOK, map[string][]machine.Machine{"machines": list})
	}
}

// FilesHandler lista pastas E arquivos de um caminho na máquina (navegador de
// arquivos da aba Máquinas). Irmão do DirsHandler, que só devolve pastas para o
// seletor de cwd ao criar uma sessão.
//
//	GET /machines/{machine}/fs?path=/Users/vx
//	→ 200 {"path","parent","entries":[…]} | 404 | 502
func FilesHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		listing, err := lch.ListFiles(r.PathValue("machine"), r.URL.Query().Get("path"))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			// A máquina é que falhou (ssh caiu, sem python3): 502, não 500.
			writeJSONError(w, http.StatusBadGateway, "fs_failed")
		default:
			writeJSONResp(w, http.StatusOK, listing)
		}
	}
}

// FileReadHandler lê um arquivo de texto da máquina. Binário ou acima do teto
// volta 200 com o conteúdo vazio e a marca (binary/truncated) — quem decide o
// que mostrar é o app.
//
//	GET /machines/{machine}/fs/read?path=/Users/vx/notas.md
//	→ 200 {"path","size","binary","truncated","content"} | 400 | 404 | 502
func FileReadHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Sem caminho não há default sensato (o "home" da listagem não se
		// traduz em arquivo): recusa antes de tocar a máquina.
		path := r.URL.Query().Get("path")
		if path == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		content, err := lch.ReadFile(r.PathValue("machine"), path)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "read_failed")
		default:
			writeJSONResp(w, http.StatusOK, content)
		}
	}
}
