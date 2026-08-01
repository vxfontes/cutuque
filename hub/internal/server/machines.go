package server

import (
	"net/http"

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
