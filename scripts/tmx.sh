#!/usr/bin/env bash
#
# tmx — atalhos de tmux para rodar agentes de terminal de um jeito que o
# Cutuque enxerga. Sessões criadas por aqui aparecem no app em
# "Continuar sessão do Mac" e podem ser controladas do iPhone/iPad/Watch.
#
# Instalação (qualquer diretório do seu PATH serve):
#
#   ln -s "$PWD/scripts/tmx.sh" /usr/local/bin/tmx
#
# Uso rápido: entre na pasta do projeto e rode `tmx cc` (Claude Code),
# `tmx cx` (Codex), `tmx oc` (OpenCode) ou `tmx gk` (Grok). Sem argumento, o
# nome da sessão vira o nome da pasta. `tmx` sozinho lista todos os comandos.
#
# Requer: tmux e o agente que você for chamar (claude / codex / opencode /
# grok).

set -e

cmd="$1"
name="$2"
arg3="$3"

SRV="${TMX_SRV:-main}"        # servidor tmux = "grupo". env TMX_SRV manda; default 'main'
TM() { tmux -L "$SRV" "$@"; } # todo tmux passa por aqui

# Onde o tmux guarda os sockets dos servidores nomeados (-L). É o mesmo default
# do tmux: $TMUX_TMPDIR, senão /tmp. Escrito assim porque este script também
# roda no macmini (Linux, root → /tmp/tmux-0), e não só no macOS: lá /tmp é
# symlink de /private/tmp, então a forma com /tmp serve nos dois.
sock_dir() { echo "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"; }

has_tmux_session() {
  TM has-session -t "$1" 2>/dev/null
}

case "$cmd" in
  new)
    if [ -z "$name" ]; then
      echo "Uso: tmx new <sessao>"
      exit 1
    fi

    if has_tmux_session "$name"; then
      echo "Sessão '$name' já existe."
    else
      TM new -s "$name"
    fi
    ;;

  newd)
    if [ -z "$name" ]; then
      echo "Uso: tmx newd <sessao>"
      exit 1
    fi

    if has_tmux_session "$name"; then
      echo "Sessão '$name' já existe."
    else
      TM new-session -d -s "$name"
      echo "Sessão '$name' criada em background (srv=$SRV)."
    fi
    ;;

  go)
    if [ -z "$name" ]; then
      echo "Uso: tmx go <sessao> [grupo]"
      exit 1
    fi

    [ -n "$arg3" ] && SRV="$arg3"   # 3º arg = grupo (servidor -L)

    if has_tmux_session "$name"; then
      TM attach -t "$name"
    else
      TM new -s "$name"
    fi
    ;;

  attach|att)
    if [ -z "$name" ]; then
      echo "Uso: tmx attach <sessao>"
      exit 1
    fi

    TM attach -t "$name"
    ;;

  ls|list)
    TM ls
    ;;

  servers)
    ls "$(sock_dir)/" 2>/dev/null || echo "(nenhum servidor tmux ativo)"
    ;;

  kill)
    if [ -z "$name" ]; then
      echo "Uso: tmx kill <sessao>"
      exit 1
    fi

    sock="$(sock_dir)/$SRV"

    # [15/08/2026] Matar a ÚLTIMA sessão encerra o servidor junto, e o tmux
    # deixa o socket pra trás (ver killservers) — sem isso o `tmx servers`
    # listaria um servidor que não existe mais. Se este shell estiver nesse
    # servidor e a sessão for a última, ele cai junto e não chega a varrer, daí
    # o varredor destacado. Quando NÃO for a última, ele confere, vê que o
    # servidor ainda responde e não faz nada.
    if [ -n "$TMUX" ] && [ "$(basename "${TMUX%%,*}")" = "$SRV" ]; then
      nohup bash -c 'sleep 1; tmux -L "$1" ls >/dev/null 2>&1 || rm -f "$2"' \
        _ "$SRV" "$sock" >/dev/null 2>&1 &
    fi

    TM kill-session -t "$name"
    echo "Sessão '$name' encerrada (srv=$SRV)."

    if [ -e "$sock" ] && ! TM ls >/dev/null 2>&1; then
      rm -f "$sock"
      echo "Era a última: servidor '$SRV' encerrado junto e socket removido."
    fi
    ;;

  killall)
    [ -n "$name" ] && SRV="$name"   # 2º arg = grupo (servidor -L)

    read -r -p "Isso vai matar TODAS as sessões do servidor '$SRV'. Continuar? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      sock="$(sock_dir)/$SRV"

      # [15/08/2026] O tmux NÃO apaga o socket ao morrer (medido; ver o bloco
      # killservers). Sem varrer, `tmx servers` seguiria listando o que este
      # comando acabou de matar.
      #
      # Caso especial que o killservers não tem: aqui o alvo pode ser o
      # servidor DESTE shell, e aí o kill-server derruba tudo antes da varrida
      # rodar. Por isso o varredor sai destacado ANTES do kill — o nohup o
      # protege do SIGHUP que o tmux manda ao sair.
      # $TMUX = "<caminho-do-socket>,<pid>,<índice>"; comparo o basename porque
      # o caminho dele pode vir por /private/tmp e o sock_dir() por /tmp.
      aqui_dentro=""
      if [ -n "$TMUX" ] && [ "$(basename "${TMUX%%,*}")" = "$SRV" ]; then
        aqui_dentro=1
        echo "! '$SRV' é o servidor em que VOCÊ está — este terminal vai cair."
        nohup bash -c 'sleep 1; tmux -L "$1" ls >/dev/null 2>&1 || rm -f "$2"' \
          _ "$SRV" "$sock" >/dev/null 2>&1 &
      fi

      if TM kill-server 2>/dev/null; then
        echo "Servidor '$SRV' encerrado."
      elif [ -e "$sock" ]; then
        echo "Servidor '$SRV' não tinha processo ativo; socket órfão removido."
      else
        echo "Servidor '$SRV' não existe."
      fi

      # caminho normal (chamado de fora do servidor): varre aqui mesmo.
      if [ -z "$aqui_dentro" ] && [ -e "$sock" ] && ! TM ls >/dev/null 2>&1; then
        rm -f "$sock"
      fi
    else
      echo "Cancelado."
    fi
    ;;

  killservers|nuke)
    # [15/08/2026] mata TODOS os servidores tmux de uma vez. Nasceu porque o
    # caminho antigo era rodar `tmx servers`, copiar nome por nome e chamar
    # `tmx killall <nome>` pra cada um.
    #
    # Varre os sockets em sock_dir() em vez de perguntar ao tmux: servidor sem
    # processo vivo não responde, mas deixa o socket pra trás — e é justamente
    # esse lixo que o `tmx servers` mostra e que a gente também quer limpar.
    #
    # 2º arg -y/--yes/-f pula a confirmação.
    dir="$(sock_dir)"

    socks=()
    for sock in "$dir"/*; do
      [ -S "$sock" ] && socks+=("$(basename "$sock")")
    done

    if [ ${#socks[@]} -eq 0 ]; then
      echo "(nenhum servidor tmux ativo)"
      exit 0
    fi

    # Servidor onde ESTE shell está, se estiver dentro de um tmux.
    # $TMUX = "<caminho-do-socket>,<pid>,<índice-da-sessão>".
    current=""
    if [ -n "$TMUX" ]; then
      maybe="$(basename "${TMUX%%,*}")"
      [ -S "$dir/$maybe" ] && current="$maybe"
    fi

    echo "Vai matar ${#socks[@]} servidor(es) tmux:"
    for s in "${socks[@]}"; do
      if out="$(tmux -L "$s" ls 2>/dev/null)"; then
        n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
        if [ "$n" -eq 1 ]; then label="1 sessão"; else label="$n sessões"; fi
      else
        label="socket órfão"
      fi
      if [ "$s" = "$current" ]; then
        printf '  %-20s (%s)  <- você está aqui\n' "$s" "$label"
      else
        printf '  %-20s (%s)\n' "$s" "$label"
      fi
    done

    force=""
    case "$name" in
      -y|--yes|-f) force=1 ;;
    esac

    if [ -z "$force" ]; then
      read -r -p "Continuar? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelado."
        exit 0
      fi
    fi

    killed=0
    orphans=0
    for s in "${socks[@]}"; do
      # o servidor da própria sessão fica pro fim: matá-lo aqui derrubaria este
      # shell no meio do laço e os servidores seguintes sobreviveriam.
      [ "$s" = "$current" ] && continue

      if tmux -L "$s" kill-server 2>/dev/null; then
        echo "  ✗ $s encerrado."
        killed=$((killed + 1))
      elif [ -e "$dir/$s" ]; then
        echo "  ✗ $s sem processo ativo; socket órfão removido."
        orphans=$((orphans + 1))
      fi

      # O tmux NÃO apaga o socket ao morrer (medido: processo some, arquivo
      # fica). Sem esta varrida o `tmux servers` continuaria listando servidor
      # morto e a limpeza não teria servido de nada. Só remove depois de
      # confirmar que ninguém mais responde naquele socket.
      if [ -e "$dir/$s" ] && ! tmux -L "$s" ls >/dev/null 2>&1; then
        rm -f "$dir/$s"
      fi
    done

    resumo="$killed servidor(es) encerrado(s)"
    [ "$orphans" -gt 0 ] && resumo="$resumo, $orphans socket(s) órfão(s) removido(s)"
    echo "$resumo."

    if [ -n "$current" ]; then
      echo
      echo "! '$current' é o servidor em que VOCÊ está — encerrando por último."
      echo "  Este terminal vai cair agora."
      # este shell morre junto com o servidor, então quem varre o socket dele é
      # um processo destacado (nohup ignora o SIGHUP que o tmux manda ao sair).
      nohup bash -c 'sleep 1; tmux -L "$1" ls >/dev/null 2>&1 || rm -f "$2"' \
        _ "$current" "$dir/$current" >/dev/null 2>&1 &
      tmux -L "$current" kill-server 2>/dev/null || true
    fi
    ;;

  rename)
    if [ -z "$name" ] || [ -z "$arg3" ]; then
      echo "Uso: tmx rename <nome-atual> <novo-nome>"
      exit 1
    fi

    TM rename-session -t "$name" "$arg3"
    echo "Sessão '$name' renomeada para '$arg3'."
    ;;

  proj)
    session_name="$(basename "$PWD" | tr ' ' '_' | tr '.' '_')"

    if has_tmux_session "$session_name"; then
      TM attach -t "$session_name"
    else
      TM new -s "$session_name"
    fi
    ;;

  cc)
    # cria (ou entra n)a sessão JÁ rodando o claude, na pasta atual.
    # Fica visível/controlável no app Cutuque ("Ao vivo no Mac").
    # 3º arg = grupo (servidor -L); senão usa $TMX_SRV / 'main'.
    if [ -z "$name" ]; then
      name="$(basename "$PWD" | tr ' ' '_' | tr '.' '_')"
    fi
    [ -n "$arg3" ] && SRV="$arg3"
    TM new-session -A -s "$name" -c "$PWD" 'claude'
    ;;

  cx)
    # igual ao cc, mas roda o codex com sandbox liberado (danger-full-access).
    # Fica visível/controlável no app Cutuque ("Ao vivo no Mac").
    # 3º arg = grupo (servidor -L); senão usa $TMX_SRV / 'main'.
    if [ -z "$name" ]; then
      name="$(basename "$PWD" | tr ' ' '_' | tr '.' '_')"
    fi
    [ -n "$arg3" ] && SRV="$arg3"
    TM new-session -A -s "$name" -c "$PWD" 'codex --sandbox danger-full-access'
    ;;

  oc)
    # igual ao cc/cx, mas roda o opencode na pasta atual.
    # Fica visível/controlável no app Cutuque ("Ao vivo no Mac").
    # 3º arg = grupo (servidor -L); senão usa $TMX_SRV / 'main'.
    if [ -z "$name" ]; then
      name="$(basename "$PWD" | tr ' ' '_' | tr '.' '_')"
    fi
    [ -n "$arg3" ] && SRV="$arg3"
    TM new-session -A -s "$name" -c "$PWD" 'opencode'
    ;;

  gk)
    # [13/08/2026] igual ao cx, mas roda o grok (xAI) na pasta atual.
    # 3º arg = grupo (servidor -L); senão usa $TMX_SRV / 'main'.
    #
    # `--always-approve` = "Auto-approve all tool executions", o equivalente ao
    # `--sandbox danger-full-access` do cx. [Reescrito em 13/08/2026, no mesmo
    # dia] Este bloco nasceu com o grok pelado e o comentário dizia que
    # auto-aprovar era decisão da Vanessa, não default do atalho. A premissa
    # segue certa — e ela decidiu: "pode botar o --always-approve no grok".
    # Então o `gk` agora é irmão do `cx`, não do `cc`/`oc`: NÃO para pedindo
    # permissão de ferramenta.
    #
    # Ressalva de visibilidade, diferente dos outros três: o hub reconhece
    # agente pelo NOME na árvore de processos ('claude'|'codex'|'opencode', ver
    # `agent_of` em hub/internal/adapter/claudecode/tmux_script.go), e 'grok'
    # não está na lista. Então a sessão aparece no app como pane de SHELL:
    # espelho e digitação funcionam (capture/send-keys são agnósticos), mas não
    # há estado rodando/esperando/ocioso. Ligar isso pede calibrar os
    # marcadores da TUI do grok por captura de tela, como foi feito pros outros.
    if [ -z "$name" ]; then
      name="$(basename "$PWD" | tr ' ' '_' | tr '.' '_')"
    fi
    [ -n "$arg3" ] && SRV="$arg3"
    TM new-session -A -s "$name" -c "$PWD" 'grok --always-approve'
    ;;

  *)
    cat <<EOF
Uso: tmx <comando> [args]   (servidor tmux = \$TMX_SRV, default 'main')

Comandos:
  new <sessao>          cria nova sessão
  newd <sessao>         cria sessão em background
  go <sessao> [grupo]   entra na sessão ou cria; grupo = servidor -L
  attach <sessao>       entra em sessão existente
  ls                    lista sessões do servidor atual
  servers               lista TODOS os servidores tmux (-L)
  kill <sessao>         mata uma sessão
  killall [grupo]       mata todas as sessões do servidor atual (ou do grupo informado)
  killservers [-y]      mata TODOS os servidores de uma vez, inclusive sockets órfãos (apelido: nuke)
  rename <a> <b>        renomeia sessão
  proj                  usa o nome da pasta atual como sessão
  cc [sessao] [grupo]   cria/entra na sessão JÁ rodando o claude; grupo = servidor -L
  cx [sessao] [grupo]   cria/entra na sessão JÁ rodando o codex (--sandbox danger-full-access); grupo = servidor -L
  oc [sessao] [grupo]   cria/entra na sessão JÁ rodando o opencode; grupo = servidor -L
  gk [sessao] [grupo]   cria/entra na sessão JÁ rodando o grok (--always-approve); grupo = servidor -L

Grupo via env:  TMX_SRV=defender tmx cc command
Grupo via arg:  tmx cc command defender
EOF
    ;;
esac
