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

    TM kill-session -t "$name"
    echo "Sessão '$name' encerrada (srv=$SRV)."
    ;;

  killall)
    [ -n "$name" ] && SRV="$name"   # 2º arg = grupo (servidor -L)

    read -r -p "Isso vai matar TODAS as sessões do servidor '$SRV'. Continuar? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      sock="$(sock_dir)/$SRV"
      if TM kill-server 2>/dev/null; then
        echo "Servidor '$SRV' encerrado."
      elif [ -e "$sock" ]; then
        rm -f "$sock"
        echo "Servidor '$SRV' não tinha processo ativo; socket órfão removido."
      else
        echo "Servidor '$SRV' não existe."
      fi
    else
      echo "Cancelado."
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
    # [13/08/2026] igual ao cc/oc, mas roda o grok (xAI) na pasta atual.
    # 3º arg = grupo (servidor -L); senão usa $TMX_SRV / 'main'.
    #
    # SEM flag, como o cc e o oc: o grok pede aprovação de cada ferramenta. Ele
    # TEM um `--always-approve` (o equivalente ao `--sandbox
    # danger-full-access` do cx), de propósito não usado aqui — auto-aprovar
    # tudo é decisão da Vanessa, não default do atalho.
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
    TM new-session -A -s "$name" -c "$PWD" 'grok'
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
  rename <a> <b>        renomeia sessão
  proj                  usa o nome da pasta atual como sessão
  cc [sessao] [grupo]   cria/entra na sessão JÁ rodando o claude; grupo = servidor -L
  cx [sessao] [grupo]   cria/entra na sessão JÁ rodando o codex (--sandbox danger-full-access); grupo = servidor -L
  oc [sessao] [grupo]   cria/entra na sessão JÁ rodando o opencode; grupo = servidor -L
  gk [sessao] [grupo]   cria/entra na sessão JÁ rodando o grok; grupo = servidor -L

Grupo via env:  TMX_SRV=defender tmx cc command
Grupo via arg:  tmx cc command defender
EOF
    ;;
esac
