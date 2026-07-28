#!/usr/bin/env bash
# Cutuque: encaminha um hook do Claude Code pro hub. Não bloqueia o claude
# (o POST vai pro background) e falha em silêncio se algo der errado.
#
# Esta é a versão VERSIONADA do script. A cópia viva fica em ~/.cutuque/hook.sh
# e é ela que o ~/.claude/settings.json chama. Para instalar/atualizar:
#
#   cp cutuque/scripts/hook.sh ~/.cutuque/hook.sh && chmod +x ~/.cutuque/hook.sh
#   printf '192.0.2.10:8787\n' > ~/.cutuque/hub-url   # o endereço REAL do seu hub
#
# Reporta pane + socket do tmux ($TMUX_PANE e o socket em $TMUX) quando o claude
# roda dentro do tmux — assim o hub sabe EXATAMENTE qual pane/servidor é a
# sessão (correlação robusta, mesmo com várias sessões na mesma pasta e com
# servidores tmux nomeados -L). Fora do tmux vão vazios (sessão local não-tmux,
# que continua notificando como antes).
#
# Dois campos existem porque o hub NÃO consegue descobri-los sozinho — ele roda
# no macmini e o disco do Mac é remoto pra ele:
#
#   reason  vem no SessionEnd e diz por que a sessão acabou (clear, resume,
#           logout, prompt_input_exit, ...). Vai pra linha do tempo.
#   title   sai do role.json do Maestri quando o cwd é uma pasta de agente.
#           Sem isso TODO agente aparecia como "personal" no app, porque o cwd
#           é .maestri/roles/<uuid> e o hub cai no nome de pasta significativo
#           mais próximo. O arquivo só existe AQUI, na máquina de origem.
TOKEN_FILE="$HOME/.cutuque/token"
# O endereço do hub NÃO fica escrito aqui: este arquivo é versionado num repo
# público, e a convenção do projeto é que endereço real só aparece como RFC 5737
# (ver README). Vem de $CUTUQUE_HUB ou de ~/.cutuque/hub-url — uma linha
# "host:porta", ao lado do token, que é o que já não é versionado. O sufixo -url é
# de propósito: "~/.cutuque/hub" lia como se o hub morasse aqui, e o hub mora no
# macmini. Sem endereço configurado o hook sai quieto, igual a quando falta token:
# nunca bloquear o claude é a regra deste script. Um endereço de exemplo como
# padrão seria pior que não tentar — faria todo POST falhar em silêncio contra um
# host que não é o seu.
HUB_FILE="$HOME/.cutuque/hub-url"
JQ=/usr/bin/jq
[ -r "$TOKEN_FILE" ] || exit 0
[ -x "$JQ" ] || exit 0
HUB_ADDR="${CUTUQUE_HUB:-}"
if [ -z "$HUB_ADDR" ] && [ -r "$HUB_FILE" ]; then
  # head -n 1: se o arquivo tiver mais de uma linha, colar tudo junto formaria um
  # endereço sem sentido ("host:8787lixo") que só ia falhar lá no curl, longe daqui.
  HUB_ADDR="$(head -n 1 "$HUB_FILE" | tr -d ' \t\r\n')"
fi
# Tolerar a URL inteira: $CUTUQUE_HUB é "host:porta" no README, mas o deck aceita
# "http://host:porta" (docs/.../cutuque-board.md), então a mesma variável circula
# nas duas formas. Sem isso o POST iria pra http://http://... e falharia mudo.
HUB_ADDR="${HUB_ADDR#http://}"
HUB_ADDR="${HUB_ADDR#https://}"
HUB_ADDR="${HUB_ADDR%/}"
[ -n "$HUB_ADDR" ] || exit 0
HUB="http://$HUB_ADDR/hooks/claude"
TOKEN="$(cat "$TOKEN_FILE")"
payload="$(cat)"

# socket do tmux = primeiro campo de $TMUX (antes da primeira vírgula).
sock="${TMUX%%,*}"

# Nome do agente Maestri, quando houver. Vazio para sessão comum — aí o hub
# escolhe o título pelo cwd, como sempre fez.
cwd="$(printf '%s' "$payload" | "$JQ" -r '.cwd // ""' 2>/dev/null)"
title=""
if [ -n "$cwd" ] && [ -r "$cwd/role.json" ]; then
  # tr+cut: título é uma linha curta. role.json é gerado pelo Maestri, mas nada
  # garante que continue assim — texto colado num campo de UI não pode vazar
  # quebra de linha nem 4KB de prompt pra dentro do app.
  title="$("$JQ" -r '.name // ""' "$cwd/role.json" 2>/dev/null | tr -d '\r\n' | cut -c1-60)"
fi

body="$(printf '%s' "$payload" | "$JQ" -c \
  --arg pane "${TMUX_PANE:-}" --arg sock "$sock" --arg title "$title" \
  '{session_id, hook_event_name, message: (.message // ""), reason: (.reason // ""), cwd: (.cwd // ""), machine: "macbook", title: $title, pane: $pane, tmux_socket: $sock}' 2>/dev/null)"
[ -n "$body" ] || exit 0
( curl -sS -m 3 -X POST "$HUB" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body" >/dev/null 2>&1 & )
exit 0
