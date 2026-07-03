# Achados de Segurança — Cutuque

## SEC-106 — `Engine.ensureRunning` reabre variante silenciosa da corrida de criação de sessão (residual do SEC-103)
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (falha de confiabilidade de um controle de segurança/aprovação, não injeção clássica)
**Localização:** `hub/internal/engine/engine.go:86-102` (`ensureRunning`, branch de criação: `Get` + `Add` bruto, não `AddIfAbsent`)
**Detectado:** 2026-07-03 | **Status:** open

**Descrição:**
O fix do SEC-103/da 4ª ocorrência do padrão `reivindicação-não-atômica-de-recurso-compartilhado` migrou `Engine.EnsureRegistered` para `Registry.AddIfAllowed` (atômico), mas `Engine.ensureRunning` — o caminho IRMÃO que também cria sessão do zero, usado tanto pelo `Runner` quanto pelo dispatch de hook `SessionStart`/`UserPromptSubmit` via `Apply` — não foi migrado junto. Seu branch de criação continua fazendo `e.reg.Get(ev.SessionID)` seguido de `e.reg.Add(session.Session{...})` bruto como duas aquisições de lock separadas.

Cenário: hook e Runner recebem o `SessionStarted` de uma sessão NUNCA vista por nenhum dos dois, quase simultaneamente — a mesma premissa do SEC-103 original. Se o `Get` de um dos dois lados retornar `exists=false` e, ANTES de seu `Add` bruto rodar, o outro lado tiver inserido E JÁ AVANÇADO o estado (ex.: processou seu próprio `EnsureRegistered`+`Apply(SessionStarted)` e, em seguida, um `Notification` de permissão real chegou primeiro, levando a sessão a `needs_you` com `PendingPrompt` preenchido), o `Add` bruto do outro lado SUBSTITUI o registro inteiro por um `session.Session{}` novo em `StateRunning` — apagando silenciosamente o `needs_you`/`PendingPrompt`/`Pane` que já existiam.

Diferença em relação ao SEC-103 original: lá, o sintoma era visível (sessão fica travada em `needs_you` sem os botões de aprovação — a usuária pelo menos VÊ que algo está preso). Aqui o resultado é PIOR em silêncio: a sessão volta a aparecer como `running`, sem nenhum badge `needs_you`, enquanto o processo `claude` real continua bloqueado esperando resposta no stdin — nenhum sinal visível de que algo está errado. A janela é mais estreita que a do SEC-103 original (exige 3 eventos entrelaçados, não 2), mas o dano pior compensa a menor probabilidade.

**Fix recomendado:**
1. Trocar o branch de criação de `ensureRunning` para `e.reg.AddIfAbsent(novaSessao)`; se `added==false`, cair no mesmo bloco de reconciliação (`Reclaim`/`UpdateState`/`SetPane`) já existente logo abaixo, hoje só executado quando `exists==true` a partir do `Get` original.
2. Regressão: teste de integração que dispara `Apply(SessionStarted)` concorrente de duas fontes para o MESMO id novo, com uma delas avançando para `needs_you` entre as duas chamadas de `Get`, e verifica que o estado final preserva `needs_you`/`PendingPrompt` em vez de reverter para `running`.

`[→ review/patterns.md#reivindicação-não-atômica-de-recurso-compartilhado]` `[relacionado a SEC-103]`

## SEC-105 — corrida de persistência em disco de device tokens (`devices/store.go`)
**Severidade:** R3 | **OWASP:** A04:2021 – Insecure Design (perda de integridade de dados de configuração, não injeção clássica)
**Localização:** `hub/internal/devices/store.go:78-91` (`persist()`, chamado fora do lock em `Upsert`/`Remove`, sem serialização entre chamadas concorrentes)
**Detectado:** 2026-07-03 | **Status:** open

**Descrição:**
`persist()` é chamado FORA do `sync.RWMutex` que protege `byToken`, tanto em `Upsert` quanto em `Remove`. O padrão interno (write em `path+".tmp"` seguido de `os.Rename`) é atômico em relação ao processo morrer no meio de UMA chamada, mas nada serializa DUAS chamadas concorrentes de `persist()` entre si — ambas compartilham o mesmo `path+".tmp"`. Cenário: um `Upsert` (app re-registrando token) concorrente com um `Remove` (disparado por um 410 Unregistered detectado no fanout de push) podem interlaçar `List()`+`Marshal`+`WriteFile`+`Rename` de forma que a chamada que TERMINA por último vence, independente de qual mutação era logicamente mais recente — o arquivo em disco pode reverter silenciosamente para um snapshot mais antigo do que o estado em memória (que, esse sim, nunca fica inconsistente sozinho, protegido corretamente pelo mutex).

Esta classe de corrida é invisível a `go test -race`: é uma corrida de I/O de arquivo do sistema operacional entre duas chamadas independentes de `os.WriteFile`/`os.Rename`, não uma corrida de memória gerenciada pelo runtime Go (que é tudo que o detector de race do Go instrumenta) — coerente com a suíte inteira do hub passando com `-race` sem acusar nada aqui.

Impacto prático: um device removido (410 do APNs) pode "voltar" no disco se seu `Remove` perder a corrida contra um `Upsert` mais antigo que ainda não tinha terminado de persistir — na pior hipótese, reenviar push para um token morto após um restart do hub (desperdiça budget de push, gera ruído de log, não expõe dado de terceiro). No sentido oposto, um `Upsert` recém-chegado pode ser perdido do disco (embora sobreviva em memória até o próximo restart).

**Fix recomendado:**
1. Um `persistMu sync.Mutex` dedicado (separado do `mu` que protege `byToken`), adquirido no INÍCIO de `persist()` e liberado só no fim, cobrindo `List()`+`Marshal`+`WriteFile`+`Rename` como uma seção crítica única — o último a adquirir o lock sempre lê o `List()` mais fresco no momento em que roda, então o resultado final em disco sempre reflete o estado mais recente, não o mais lento a terminar.
2. Teste de regressão com N goroutines concorrentes chamando `Upsert`/`Remove`, seguido de verificação de que o conteúdo final em disco bate com `List()` em memória.
3. Non-blocking relacionado: `persist()`/`load()` engolem erros de I/O silenciosamente — vale um `slog.Warn` nos `return` de erro para não perder o sinal operacional de um disco cheio/sem permissão.

`[→ review/patterns.md#persistência-em-disco-fora-da-seção-crítica]`

## SEC-104 — colisão de pane cross-máquina (chave composta sem dimensão de `machine`)
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (isolamento insuficiente entre sessões/máquinas diferentes)
**Localização:** hub: `hub/internal/server/hooks.go:32-43` (`hookPayload.paneTarget()`, nunca inclui `machine`), `hub/internal/registry/registry.go:189-230` (`SetPane`, loop de eviction compara só `os.Pane == pane`, falta `&& os.Machine == s.Machine`). app: `app/CutuqueApp/SessionListView.swift` (`LiveEntry.id`, `livePaneIDs`, `needsYouPaneIDs`, `others`, `liveState(_:)` — todos comparam `tmuxTarget`/pane como `String` sem `machine`)
**Detectado:** 2026-07-03 | **Status:** open

**Descrição:**
O alvo tmux composto (`"<socket>\t<pane>"`, montado em `hookPayload.paneTarget()`) nunca inclui a máquina em NENHUM lugar do código, nem no hub nem no app. Como tmux usa por padrão o socket "default" e a primeira pane de uma sessão sempre é "%0", duas máquinas diferentes rodando cada uma uma sessão tmux default colidem na MESMA string de pane com boa probabilidade na prática — o Cutuque já suporta multi-máquina nativamente (`Launcher.targets`/`SSHTarget`/`LocalTarget`, endpoints `/machines/{machine}/tmux`, `/machines/{machine}/live`), então esta não é uma configuração hipotética.

No hub: `Registry.SetPane`'s loop de eviction (linhas 206-217) varre TODAS as sessões procurando `os.Pane == pane` sem checar `os.Machine == s.Machine` — uma sessão `needs_you` na Máquina A pode ser evictada (pane limpo, estado forçado para `done`) por uma sessão nova que só coincide na string de pane na Máquina B, dado de outra máquina interferindo silenciosamente no estado de uma sessão não relacionada.

No app: `livePaneIDs`/`needsYouPaneIDs` (`SessionListView.swift`) são `Set<String>` construídos a partir de TODAS as máquinas configuradas sem incluir `machine` na chave, e `liveState(_:)` faz `model.sessions.first(where: { $0.tmuxTarget == entry.id })` sem filtrar por máquina — uma linha "Ao vivo" da Máquina B pode herdar o estado/dedup de uma sessão da Máquina A que colide na string de pane. Consequência mais grave: uma sessão `needs_you` mostrando um `pendingPrompt` de uma máquina, ao ser tocada, pode rotear a interação (capture-pane/send-keys) para o terminal ao vivo de OUTRA máquina/sessão que coincide na string de pane — a usuária pode digitar uma resposta pensando estar respondendo a um prompt quando na verdade está interagindo com um processo totalmente diferente.

**Fix recomendado:**
1. Patch mínimo imediato no hub: adicionar `&& os.Machine == s.Machine` à condição de eviction em `SetPane`.
2. Fix durável: incluir `machine` na própria chave composta (`"<machine>\t<socket>\t<pane>"`) em TODO lugar onde ela é construída/comparada — `hooks.go: paneTarget()`, `registry.go: SetPane`, e no app: `LiveEntry`/`tmuxTarget`/os sets de dedup — para que nenhum código futuro que compare panes precise lembrar de checar `machine` separadamente.
3. Regressão: teste no hub simulando duas sessões de máquinas diferentes com o mesmo `pane`/`socket`, verificando que `SetPane` não evicta a sessão da outra máquina.

`[→ review/patterns.md#chave-composta-sem-dimensão-de-desambiguação]`

## SEC-103 — corrida hook-vs-runner pode travar permanentemente o gate de aprovação de sessão `-p` lançada pelo hub
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (falha de confiabilidade de um controle de segurança/aprovação, não injeção clássica)
**Localização:** `hub/internal/engine/engine.go:86-107` (`ensureRunning`, nunca corrige `External`/`Title`/`Machine`/`Agent` quando a sessão já existe), `hub/internal/engine/engine.go:117-146` (`EnsureRegistered`, sempre cria com `External: true`), `hub/internal/server/hooks.go:111-125` (`HookHandler`, chama `EnsureRegistered` incondicionalmente para todo hook, inclusive de sessões `-p` lançadas pelo próprio hub), `app/CutuqueApp/SessionDetailView.swift` (`permissionPrompt`, gated a `!model.session.isExternal` — sem esse gate aberto não há canal de aprovação para sessão headless)
**Detectado:** 2026-07-03 | **Status:** RESOLVIDO (2026-07-03, para o cenário originalmente reportado — ver ressalva)

**Resolução (2026-07-03):**
`Registry.Reclaim(id, title, machine, agent)` (`registry.go`) foi introduzido e é chamado a partir de `Engine.ensureRunning` (`engine.go`) sempre que `!ev.External && cur.External` — ou seja, quando um evento AUTORITATIVO do `Runner` (`ev.External == false`) chega para uma sessão que hoje está marcada `External == true` (criada primeiro por um hook). `Reclaim` corrige `External` para `false` e atualiza `Title`/`Machine`/`Agent` a partir do evento do Runner, fechando exatamente a janela descrita originalmente: não importa mais qual fonte chega primeiro, o Runner sempre consegue "reclamar" a sessão como hub-owned quando seu próprio evento chega. Confirmado via leitura de código (`engine.go`, `registry.go`) — o mecanismo bate com a opção 1 do fix originalmente recomendado.

**Ressalva (2026-07-03):** o MESMO branch de `ensureRunning` que chama `Reclaim` (usado quando a sessão JÁ existe) está correto; mas o branch IRMÃO — criação de sessão DO ZERO, quando nenhum dos dois lados jamais viu o id antes — continua fazendo `Get`+`Add` bruto, não `AddIfAbsent`, reabrindo uma variante mais estreita (e mais silenciosa) da mesma classe de corrida. Rastreada separadamente como **SEC-106** (não reabre este ticket porque o cenário aqui descrito — sessão já registrada por um lado, reclamada pelo outro — está genuinamente fechado; o residual é uma janela de timing distinta, na criação concorrente do zero).

**Descrição original (mantida para contexto histórico):**
O forwarder de hook (`~/.cutuque/hook.sh`) é configurado a nível de usuário no Claude Code e dispara para TODA sessão `claude` rodando no Mac — inclusive as sessões `claude -p` que o próprio hub lança localmente via `Launcher`/`Runner` (stream-json), e agentes de terceiros que também chamem `claude` na mesma máquina. Isso cria DUAS fontes independentes de eventos para o MESMO `session_id`, sem nenhuma ordenação garantida entre elas. Se o hook vencesse a corrida, a sessão ficava marcada `External = true` de forma permanente, e o app (gated a `!isExternal` para mostrar os botões aprovar/negar) não oferecia nenhum canal de resposta para uma sessão `-p` headless — o agente ficava bloqueado no `control_request` indefinidamente.

## SEC-102 — corrida entre heartbeat de foreground e transição para background pode suprimir push indefinidamente
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (falha de design em um controle de segurança/alerta, não injeção clássica)
**Localização:** `app/CutuqueApp/ForegroundReporter.swift:36-50` (heartbeat `active:true` + envio imediato de `active:false` ao sair), `hub/internal/notifier/notifier.go:92-111` (`SetForeground`, agora com `fgMu`/`fgLastAt`), `hub/internal/notifier/notifier.go` (`fanout`, ponto onde a supressão é aplicada)
**Detectado:** 2026-07-03 | **Status:** RESOLVIDO (2026-07-03)

**Resolução (2026-07-03):**
`Notifier.SetForeground` (`notifier.go:94-111`) agora recebe um timestamp lógico (`at`) do cliente e usa `fgMu`/`fgLastAt` para descartar updates fora de ordem (`if at < n.fgLastAt { return }`) antes de aplicar `foregroundUntil` — exatamente o fix recomendado originalmente (timestamp/sequência monotônica do cliente, aplicado no hub por ordem LÓGICA, não por ordem de chegada na rede). Confirmado via leitura de código. Não foi verificado neste round se o cliente (`ForegroundReporter.swift`) já envia o `at` correspondente no corpo de `POST /app/foreground` — vale uma confirmação rápida do payload do app na próxima leva que tocar este arquivo, mas o mecanismo do lado do hub está correto e é a peça que fecha a corrida relatada.

**Descrição original (mantida para contexto histórico):**
A feature de supressão de push por foreground dependia de duas requisições HTTP independentes e sem sequência lógica entre si (heartbeat `active:true` a cada 60s + saída imediata `active:false`). `SetForeground` só fazia `Store` num `atomic.Int64`, que garante atomicidade de acesso mas não ordem causal — o hub aplicava o que chegasse por último na rede, não o que tivesse acontecido por último no cliente, podendo reabrir a janela de supressão por até 150s mesmo com o app em background.

## SEC-101 — OS command injection via `id` (Adopt) no SSHTarget
**Severidade:** R1 | **OWASP:** A03:2021 – Injection
**Localização:** `hub/internal/adapter/claudecode/target.go:344-374` (`remoteClaudeCommand`, `singleQuote`), exposto via `hub/internal/launcher/launcher.go:207-227` (`Adopt`) e `:332-373` (`resume`, linha 348: `tgt.Start(l.baseCtx, s.ID, s.Cwd)`), aceito sem validação em `hub/internal/server/launch.go:50-77` (`AdoptHandler`, valida só `req.ID != ""`)
**Detectado:** 2026-07-03 | **Status:** RESOLVIDO (2026-07-03)

**Resolução (2026-07-03):**
Os três pontos do fix recomendado foram aplicados e verificados:
1. `remoteClaudeCommand` (`target.go`) reescrito com o idioma `bash -lc 'exec "$0" "$@"' <argv...>`, cada arg single-quoted individualmente — o `bash` interno não reparseia mais os args como shell.
2. `Launcher.Adopt` (`launcher.go`) valida `id` contra `sessionIDPattern = ^[0-9a-fA-F-]{8,64}$` → `ErrInvalidSessionID`; `AdoptHandler` mapeia para `400 invalid_session_id`.
3. Comentário de `singleQuote` atualizado (protege UM nível; ver `remoteClaudeCommand` para o caso aninhado).

Testes de regressão: `TestRemoteClaudeCommandNeutralizesInjection` (5 payloads: `;`, `&&`, `$()`, backticks, `$()` isolado — nenhum executa, arg chega intacto), `TestAdoptRejectsInvalidID`, `TestAdoptInvalidSessionID` (server → 400). Verificado no hub deployado: id malicioso → 400 `invalid_session_id`, sem artefato de injeção no servidor.

**Verificação de não-regressão (2026-07-03, leva de histórico/live/foreground):**
`SSHTarget.Transcript` (`transcript.go:124-127`) reusa o MESMO `singleQuote`/único nível de shell (sem `bash -lc` aninhado) e depende de `Launcher.Adopt` já ter validado `id` via `sessionIDPattern` antes de qualquer chamada (único call site, confirmado via grep). `Live`/`live.go` não recebe nenhum input do cliente — script é uma constante Go, `machine` só indexa o mapa fixo de targets. **SEC-101 não regrediu.**

**Verificação de não-regressão (2026-07-03, leva do hook de aviso / pane composto):**
`hub/internal/adapter/claudecode/tmux.go` estende o mesmo target composto (`"<socket>\t<pane>"`) para 4 novas operações (`TmuxCapture`/`Send`/`Key`/`Resize`), todas client-facing via HTTP (`hub/internal/server/launch.go`). Confirmado seguro: `parseTarget` valida pane (`^%[0-9]+$`) e socket (`^/[A-Za-z0-9._/ -]+$`) — ambos rejeitam `;`, `$()`, aspas, backtick — ANTES de qualquer uso; todo valor validado passa por `singleQuote` em cada call site; um único nível de shell (`ssh dest "<cmd>"`, sem `bash -lc` aninhado); `TmuxKey` restringe `key` a um allowlist fixo (`tmuxAllowedKeys`); `TmuxSend` usa `-l --` (literal + fim-de-opções) no `send-keys`. O espaço permitido no regex do socket não é explorável (sempre entra em UM argumento via `singleQuote`, com ou sem espaço). **SEC-101 não regrediu.**

**Verificação de não-regressão (2026-07-03, leva de Notification ociosa / devices / Resolve):**
Nenhuma mudança nesta leva toca `remoteClaudeCommand`/`singleQuote`/`Adopt`. O novo endpoint `POST /sessions/{id}/resolve` (`ResolveHandler`) só aceita o `id` já existente no Registry (path param, não usado para montar comando algum) e chama `Launcher.Resolve` → `reg.UpdateState(id, StateDone)` — sem tocar em `exec`/`ssh`. **SEC-101 não regrediu.**

**Descrição:**
`POST /machines/{machine}/adopt` aceita `id` livre do cliente (app) e grava como `Session.ID` no registry sem validar formato. Quando essa sessão (idle, sem handle vivo) recebe `POST /sessions/{id}/input`, `Launcher.SendText` cai em `resume()`, que chama `tgt.Start(ctx, s.ID, s.Cwd)` com `s.ID` = o `id` fornecido pelo cliente. Para `SSHTarget`, isso vira `--resume <id>` dentro de `remoteClaudeCommand`, que monta:

```
bash -lc '<claude -p --resume <id> --input-format ... --verbose>'
```

O `id` entra na string que é o ARGUMENTO de um `bash -lc` ANINHADO. `singleQuote` escapa corretamente para o shell de login que o `sshd` invoca (nível 1), mas esse nível 1 apenas entrega a string inteira, já sem as aspas externas, como o argumento `-c` do `bash` interno (nível 2) — que a REPARSEIA como uma nova linha de comando (word-splitting, `;`, `&&`, `$()`, etc. voltam a valer). Ou seja, o escape de `singleQuote` protege só o nível externo; o `id` nunca é isolado como um token opaco no nível interno.

PoC local (fora do sandbox de produção, sem tocar em nenhuma máquina real) confirmou execução: com `id = "X; touch <arquivo> #"`, o comando resultante, executado como o `sshd` executaria (`shell -c "<string>"`), efetivamente rodou o `touch` injetado.

Antes desta feature, `s.ID` só podia vir do próprio `claude` (evento `session_started`, UUID gerado pela CLI) — nunca de input direto do cliente. O `Adopt` introduz a primeira via pela qual um chamador com o `CUTUQUE_TOKEN` controla literalmente o conteúdo do `--resume <id>`, alcançando RCE como o usuário SSH remoto em qualquer máquina cadastrada como `SSHTarget`. `LocalTarget` NÃO é afetado (Go `exec.Command` não passa por shell, `id` vira um argv isolado).

**Fix recomendado:**
1. Corrigir a construção do comando remoto para não reparsear o payload num shell aninhado — usar o idioma `bash -lc 'exec "$0" "$@"' <argv0> <argv1> ...`, quotando CADA argumento individualmente (inclusive os fixos), em vez de juntar tudo numa string e quotar o conjunto:

```go
func remoteClaudeCommand(claudeCmd, resumeID, cwd string) string {
    args := []string{claudeCmd, "-p"}
    if resumeID != "" {
        args = append(args, "--resume", resumeID)
    }
    args = append(args,
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--permission-mode", "default",
        "--permission-prompt-tool", "stdio",
        "--verbose",
    )
    quoted := make([]string, len(args))
    for i, a := range args {
        quoted[i] = singleQuote(a)
    }
    cmd := "bash -lc " + singleQuote(`exec "$0" "$@"`) + " " + strings.Join(quoted, " ")
    if cwd != "" {
        cmd = "cd " + singleQuote(cwd) + " && " + cmd
    }
    return cmd
}
```
   Validado localmente: com o mesmo `id` malicioso, o comando resultante não executa o `touch` injetado (o valor chega inteiro e literal em `$@`, sem ser reinterpretado pelo bash interno).

2. Defesa em profundidade em `AdoptHandler`/`Launcher.Adopt`: validar `id` contra o formato real de session id do Claude Code (ex.: `^[0-9a-fA-F-]{8,64}$`) e rejeitar com 400 se não bater — evita que qualquer variação futura de construção de comando reabra a mesma classe de bug.
3. Atualizar o comentário de `singleQuote` (target.go:369-371), que hoje diz não ser um escapador genérico para input externo — hoje é exatamente isso que ele faz, então o comentário deve refletir a garantia real após o fix (isolamento correto por token via `"$@"`, não por concatenação+quote único).
</content>
