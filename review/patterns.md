# Padrões Recorrentes — Cutuque

Alimentado quando um padrão aparece pela 2ª vez ou mais.

## ssh-remote-script-sem-login-shell
**Categoria:** design | performance/reliability
**Frequência:** 3x | **Primeira vez:** 2026-07-03 (`discover.go`) | **Última:** 2026-07-03 (`live.go`, `transcript.go`)
**Descrição:** Os três adapters que rodam scripts Python numa máquina remota via SSH (`SSHTarget.Discover`, `SSHTarget.Live`, `SSHTarget.Transcript`) montam o comando remoto como `ssh <sshBaseOpts> -- <dest> "python3 -"`, sem envolver em `bash -lc` (login shell) — diferente do padrão usado para rodar o próprio `claude` (`remoteClaudeCommand`, que usa login shell explicitamente). Sem login shell, o comando remoto roda no shell não-interativo default do `sshd` (geralmente `sh`, não necessariamente lendo `.bashrc`/`.zshrc`/`.profile`), o que pode não ter o mesmo `PATH` de uma sessão interativa — um `python3` instalado via um gerenciador de versão (pyenv/asdf/homebrew em PATH customizado no `.zshrc`) pode não ser encontrado, fazendo `Discover`/`Live`/`Transcript` falharem silenciosamente (erro tratado como `ErrDiscoverFailed`/falha do `importTranscript`) em máquinas com esse tipo de setup, mesmo que o `claude` em si funcione (porque esse SIM usa login shell).
**Recomendação:** Ajustar o helper compartilhado (`runDiscoverScript` em `discover.go`, reusado por `live.go`, e o equivalente `runTranscript` em `transcript.go`) para envolver o `python3 -` em `bash -lc` também, na mesma linha do que já é feito para o `claude`. Corrigir uma única vez no nível do helper compartilhado evita que a mesma decisão precise ser revisitada em cada novo adapter (`Discover`/`Live`/`Transcript` hoje; qualquer script remoto futuro herdaria o mesmo problema se copiado do padrão atual).

## shell-command-por-string-reparseada-em-shell-aninhado
**Categoria:** security
**Frequência:** 1x (candidato — critério de promoção é 2x) | **Primeira vez:** 2026-07-03
**Descrição:** construir um comando remoto concatenando argumentos numa única string e depois envolvê-la em UM NÍVEL de single-quote para passar a um `bash -lc` — o valor quotado vira o argumento `-c` de um shell ANINHADO, que o reparseia como sintaxe de shell, anulando o escape do nível externo para qualquer input que contenha `;`, `&&`, `$()`, etc. Visto em `hub/internal/adapter/claudecode/target.go` (`remoteClaudeCommand`), causa raiz do SEC-101 (corrigido). Confirmado nesta leva (transcript.go/live.go) que o padrão NÃO se repetiu — ambos usam um único nível de shell.
**Recomendação:** se reaparecer em outro adapter (ex.: um futuro `DockerTarget`/`K8sTarget`), promover a entrada completa aqui com recomendação: usar `bash -lc 'exec "$0" "$@"' arg0 arg1 ...` (cada argv quotado individualmente) em vez de string única reparseada.
</content>
