#!/usr/bin/env bash
# Testa scripts/hook.sh sem tocar em nada real: HOME temporário e um `curl` falso
# no início do PATH que grava a chamada num arquivo em vez de sair na rede.
#
# Rodar: scripts/hook-test.sh   (do diretório raiz do repo ou de qualquer lugar)
#
# O que está sob teste é sobretudo a RESOLUÇÃO DO ENDEREÇO, que é onde o script
# tem mais chance de falhar em silêncio: ele nunca pode bloquear o claude, então
# todo erro vira "exit 0 sem POST" — indistinguível de sucesso a olho nu.
set -u

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$AQUI/hook.sh"
BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# curl falso: grava a linha de comando inteira e a última flag -d (o corpo).
STUB="$BASE/bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
STUBEOF
chmod +x "$STUB/curl"

ok=0; falhou=0

# roda o hook num HOME limpo. $1 = payload no stdin. Ecoa o que o curl recebeu.
executa() {
  local payload="$1"; shift
  export HOME="$BASE/home"
  rm -rf "$HOME"; mkdir -p "$HOME/.cutuque"
  export CURL_LOG="$BASE/curl.log"
  : > "$CURL_LOG"
  # cada caso monta o ~/.cutuque como quiser antes de chamar o hook
  "$@"
  # via `bash` e não direto: o modo do arquivo no repo não é o que está sob teste,
  # e um "permission denied" aqui viraria "nenhum POST" — que é exatamente o que
  # os casos negativos esperam. Sem isso o suíte passa por engano quando quebra.
  printf '%s' "$payload" | PATH="$STUB:$PATH" bash "$HOOK"
  # o POST vai pro background ( ... & ); dar um tempo curto pra ele materializar
  local i=0
  while [ ! -s "$CURL_LOG" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i+1)); done
  cat "$CURL_LOG"
}

verifica() {
  local nome="$1" esperado="$2" obtido="$3"
  if [[ "$obtido" == *"$esperado"* ]]; then
    ok=$((ok+1)); printf 'ok   %s\n' "$nome"
  else
    falhou=$((falhou+1))
    printf 'FALHOU %s\n  esperava conter: %s\n  obtido:          %s\n' \
      "$nome" "$esperado" "${obtido:-<vazio>}"
  fi
}

verifica_vazio() {
  local nome="$1" obtido="$2"
  if [ -z "$obtido" ]; then
    ok=$((ok+1)); printf 'ok   %s\n' "$nome"
  else
    falhou=$((falhou+1)); printf 'FALHOU %s\n  esperava NENHUM POST, obtido: %s\n' "$nome" "$obtido"
  fi
}

P='{"session_id":"s1","hook_event_name":"Stop","cwd":"/tmp"}'
PEND='{"session_id":"s1","hook_event_name":"SessionEnd","reason":"clear","cwd":"/tmp"}'

# --- sem os pré-requisitos, sai quieto -------------------------------------
unset CUTUQUE_HUB
verifica_vazio 'sem token nem endereço: nada é enviado' \
  "$(executa "$P" true)"

verifica_vazio 'token sem endereço: nada é enviado (não inventa host)' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"')"

verifica_vazio 'endereço sem token: nada é enviado' \
  "$(executa "$P" bash -c 'printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"

verifica_vazio 'hub-url vazio: nada é enviado' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; : > "$HOME/.cutuque/hub-url"')"

# --- resolução do endereço ---------------------------------------------------
prep() { printf tk > "$HOME/.cutuque/token"; printf '%s' "$1" > "$HOME/.cutuque/hub-url"; }
export -f prep 2>/dev/null || true

verifica 'hub-url simples vira URL do endpoint' 'http://192.0.2.10:8787/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"

verifica 'hub-url com espaços e CRLF é aparado' 'http://192.0.2.10:8787/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "  192.0.2.10:8787 \r\n" > "$HOME/.cutuque/hub-url"')"

verifica 'hub-url com URL inteira: esquema é descartado, não duplicado' 'http://192.0.2.10:8787/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "http://192.0.2.10:8787/\n" > "$HOME/.cutuque/hub-url"')"

verifica 'hub-url https também é aceito como endereço' 'http://192.0.2.10:8787/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "https://192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"

verifica 'hub-url multilinha: só a primeira linha conta' 'http://192.0.2.10:8787/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\nlixo\n" > "$HOME/.cutuque/hub-url"')"

export CUTUQUE_HUB=192.0.2.99:9999
verifica 'CUTUQUE_HUB vence o arquivo' 'http://192.0.2.99:9999/hooks/claude' \
  "$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"
unset CUTUQUE_HUB

# --- corpo do POST -----------------------------------------------------------
saida="$(executa "$PEND" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"
verifica 'SessionEnd carrega o reason'   '"reason":"clear"'        "$saida"
verifica 'machine é preenchido'          '"machine":"macbook"'     "$saida"
verifica 'token vai no header'           'Bearer tk'               "$saida"

# title sai do role.json do cwd; sem role.json fica vazio e o hub decide
saida="$(executa '{"session_id":"s1","hook_event_name":"SessionStart","cwd":"'"$BASE"'/papel"}' \
  bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"
           mkdir -p '"$BASE"'/papel; printf "{\"name\":\"cutuque\"}" > '"$BASE"'/papel/role.json')"
verifica 'title vem do role.json do cwd' '"title":"cutuque"'       "$saida"

saida="$(executa "$P" bash -c 'printf tk > "$HOME/.cutuque/token"; printf "192.0.2.10:8787\n" > "$HOME/.cutuque/hub-url"')"
verifica 'sem role.json o title vai vazio' '"title":""'            "$saida"

printf '\n%d ok, %d falhou\n' "$ok" "$falhou"
[ "$falhou" -eq 0 ]
