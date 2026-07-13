package server

import (
	_ "embed"
	"html"
	"net/http"
	"strings"
)

// boardProtocolMD é o protocolo do board para os agentes, embutido no binário e
// servido em GET /board-protocol (aberto) — assim é lido via Tailscale sem
// precisar de nada na máquina de ninguém.
//
//go:embed board-protocol.md
var boardProtocolMD string

// boardProtocolPage embrulha o markdown cru num HTML mínimo (dark, monospace)
// só para leitura confortável no navegador; o conteúdo é escapado.
func boardProtocolPage() []byte {
	return []byte(`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">` +
		`<meta name="viewport" content="width=device-width,initial-scale=1">` +
		`<title>Cutuque Board — Protocolo</title>` +
		`<style>body{margin:0;background:#0b0e14;color:#e6edf3;` +
		`font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}` +
		`pre{white-space:pre-wrap;word-wrap:break-word;max-width:900px;margin:0 auto;padding:28px 20px}</style>` +
		`</head><body><pre>` + html.EscapeString(boardProtocolMD) + `</pre></body></html>`)
}

// BoardProtocolHandler serve o protocolo do board com content-negotiation:
// navegador (Accept: text/html) recebe a página estilizada; curl/agentes
// recebem o markdown CRU (limpo, sem HTML/escape) para ler e seguir.
func BoardProtocolHandler() http.HandlerFunc {
	page := boardProtocolPage()
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if strings.Contains(r.Header.Get("Accept"), "text/html") {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write(page)
			return
		}
		// curl/agentes: markdown cru.
		w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
		_, _ = w.Write([]byte(boardProtocolMD))
	}
}
