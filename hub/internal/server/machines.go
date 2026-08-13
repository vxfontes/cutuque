package server

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"path/filepath"

	"github.com/vxfontes/cutuque/hub/internal/adapter/claudecode"
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

// FileReadHandler lê um arquivo de texto da máquina. Binário volta 200 com o
// conteúdo vazio e a marca (binary); texto acima do teto volta com a CAUDA do
// arquivo e a marca (truncated+tail), não mais vazio (12/08/2026) — quem
// decide o que mostrar é o app.
//
//	GET /machines/{machine}/fs/read?path=/Users/vx/notas.md
//	→ 200 {"path","size","binary","truncated","tail","content"} | 400 | 404 | 502
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

// fileWriteReq é o corpo do PUT /fs/write. O conteúdo vai como string JSON
// (texto), não base64: o editor do app só abre arquivo de texto, e o JSON já
// resolve escape e UTF-8. Binário não é editável por aqui — só baixável.
type fileWriteReq struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// FileWriteHandler salva um arquivo de texto na máquina. SÓ sobrescreve arquivo
// existente: caminho que não é arquivo devolve 404 not_a_file. Não cria arquivo
// novo, não apaga, não move — o painel Arquivos é ler/baixar/editar.
//
//	PUT /machines/{machine}/fs/write  {"path","content"}
//	→ 200 {"path","size"} | 400 | 404 | 502
func FileWriteHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req fileWriteReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		// Conteúdo vazio é legítimo: a usuária pode ter apagado tudo.
		res, err := lch.WriteFile(r.PathValue("machine"), req.Path, []byte(req.Content))
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case errors.Is(err, claudecode.ErrNotAFile):
			// Sumiu ou virou pasta desde que a usuária abriu: 404, não 502 — o
			// app precisa distinguir isso de "a máquina caiu".
			writeJSONError(w, http.StatusNotFound, "not_a_file")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "write_failed")
		default:
			writeJSONResp(w, http.StatusOK, res)
		}
	}
}

// FileDownloadHandler devolve os bytes crus de um arquivo — inclusive binário,
// que o visualizador não mostra. Resposta é o arquivo em si, não JSON.
//
// EM FLUXO desde 12/08/2026: lch.DownloadFile devolve um io.ReadCloser que o
// io.Copy drena direto para w, sem o arquivo inteiro passar pela memória do
// hub — um vídeo de 2 GB não pode ser a diferença entre atender o pedido e
// derrubar o processo que também segura board, sessões e terminais.
//
//	GET /machines/{machine}/fs/download?path=/Users/vx/foto.png
//	→ 200 <bytes> | 400 | 404 | 502
func FileDownloadHandler(lch Launcher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Query().Get("path")
		if path == "" {
			writeJSONError(w, http.StatusBadRequest, "bad_request")
			return
		}
		rc, err := lch.DownloadFile(r.PathValue("machine"), path)
		switch {
		case errors.Is(err, launcher.ErrUnknownMachine):
			writeJSONError(w, http.StatusNotFound, "unknown_machine")
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "download_failed")
		default:
			defer rc.Close() // é o Close() que espera o processo (cat/ssh) e evita zumbi
			// Sem o attachment o iOS tenta renderizar em vez de salvar. O nome
			// vai pelo mime.FormatMediaType, que escapa aspas e recusa
			// caracteres de controle — o nome vem do caminho digitado, então
			// não pode virar injeção de header.
			cd := mime.FormatMediaType("attachment", map[string]string{"filename": filepath.Base(path)})
			if cd == "" {
				cd = "attachment"
			}
			w.Header().Set("Content-Disposition", cd)
			w.Header().Set("Content-Type", "application/octet-stream")
			w.WriteHeader(http.StatusOK)
			// A partir daqui o 200 e os headers já foram para o cliente. Se o
			// cat/ssh falhar no meio (arquivo sumiu, ssh caiu), io.Copy só
			// devolve um erro TARDIO: não dá para trocar o status depois de
			// escrito, nem colar um corpo de erro JSON no meio de bytes
			// binários — os dois ficariam corrompidos. Por isso só encerra a
			// resposta aqui; o cliente recebe um arquivo incompleto, que é o
			// melhor possível sem voltar a bufferizar (a própria razão desta
			// mudança).
			_, _ = io.Copy(w, rc)
		}
	}
}
