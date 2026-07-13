package server

import (
	_ "embed"
	"net/http"
)

// cutuqueCLI é a CLI `cutuque` empacotada num único arquivo Node, embutida no
// binário do hub e servida em GET /cutuque. Assim os agentes instalam via
// Tailscale (curl), sem precisar do repo na máquina. Gerada por
// board/scripts/bundle.mjs e copiada para cá.
//
//go:embed cutuque.js
var cutuqueCLI []byte

// installScript instala a CLI baixando /cutuque para um dir do PATH. Servido em
// GET /install (curl .../install | sh). O hub só é alcançável no Tailscale.
const installScript = `#!/bin/sh
set -e
HUB="${CUTUQUE_HUB_URL:-http://192.0.2.10:8787}"
BIN="${CUTUQUE_BIN:-/usr/local/bin}"
[ -w "$BIN" ] 2>/dev/null || BIN="$HOME/.local/bin"
mkdir -p "$BIN"
curl -fsSL "$HUB/cutuque" -o "$BIN/cutuque"
chmod +x "$BIN/cutuque"
echo "cutuque instalado em $BIN/cutuque"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "aviso: adicione $BIN ao PATH (ex.: export PATH=\"$BIN:\$PATH\")";; esac
`

// BoardCLIHandler serve o executável da CLI (arquivo Node único).
func BoardCLIHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(cutuqueCLI)
	}
}

// BoardInstallHandler serve o script de instalação (curl … | sh).
func BoardInstallHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(installScript))
	}
}
