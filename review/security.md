# Achados de Segurança — Cutuque

## SEC-108 — `Launcher.resume` não tem timeout/sinal de falha quando o processo do agente não produz nenhuma saída (amplificado pelo Codex)
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (ausência de sinal de falha num controle de estado, não injeção clássica)
**Localização:** `hub/internal/launcher/launcher.go:670-711` (`resume`, sem timeout/espera de confirmação, diferente de `Launch`), `hub/internal/adapter/agent/runner.go:104-107` (`Run`, só sintetiza `Errored` no EOF se `sessionID != ""`, i.e., se algum `session_started`/`thread.started` chegou a ser visto)
**Detectado:** 2026-07-06 | **Status:** open

**Descrição:**
`Launcher.Launch` (primeira mensagem de uma sessão) espera até `launchTimeout` (20s) por um `session_started`; se o processo morrer antes disso, `ErrLaunchTimeout` é devolvido ao cliente. `Launcher.resume` (toda continuação de uma sessão já encerrada — `SendText`/`Reply` quando não há handle vivo) **não tem esse mecanismo**: ele inicia o processo, ecoa o prompt do usuário no output (`l.eng.Apply(OutputChunk kind=user, ...)`, ANTES de qualquer confirmação de que o processo vai realmente responder) e retorna 200 imediatamente, sem esperar nem por um `thread.started`/`session_started` nem por um evento terminal.

`agent.Runner.Run` só sintetiza um evento `Errored` no EOF quando `sessionID != ""` — ou seja, apenas quando o adapter já viu pelo menos um evento com id (tipicamente o primeiro, `session_started`/`thread.started`). Se o processo do agente morrer/sair ANTES de emitir qualquer linha JSON no stdout (`cmd.Start()` teve sucesso, mas o binário em si falhou/saiu sem imprimir nada — ex.: erro de auth/quota impresso só no stderr, ou, no caminho SSH, o binário `codex`/`claude` remoto não está no PATH do shell não-interativo e o `bash -lc` retorna "command not found" só no stderr), **nenhum evento é emitido, a sessão fica congelada no estado anterior (tipicamente `done`), e a usuária nunca recebe erro nem resposta** — só o eco do próprio texto que ela mandou, já aplicado antes do processo sequer confirmar que ia rodar.

Isso é uma fraqueza pré-existente do `resume` (compartilhado por Claude e Codex desde antes desta leva), mas o Codex a expõe com frequência MUITO maior: como o Codex é one-shot (cada mensagens após a primeira SEMPRE passa por `resume`, nunca por stdin de um processo já vivo — ao contrário do Claude, que só usa `resume` quando a sessão já encerrou), qualquer máquina SSH nova onde o binário `codex` ainda não esteja corretamente instalado/no PATH faz TODA mensagem de continuação cair nesse buraco, silenciosamente, sem log nem timeout.

**Fix recomendado:**
1. Dar a `resume` o mesmo tratamento de `Launch`: um timeout curto esperando confirmação de vida do processo (ex.: o primeiro evento do stream, ou ao menos um sinal de "processo ainda respondendo" — não precisa ser um `session_started` novo, já que o id é o mesmo (`forcedID`)); se estourar, aplicar um `Errored` explícito na sessão (em vez de deixá-la congelada) e devolver erro ao chamador.
2. Alternativa mais barata: em `agent.Runner.Run`, sintetizar `Errored` no EOF mesmo com `sessionID == ""` QUANDO a chamada é de um resume (`forcedID` conhecido) — hoje esse conhecimento só existe no `launchApplier`, não no `Runner`; dá pra propagar via `Meta` (ex.: `Meta.ForceErrorOnEmptyEOF bool` ou simplesmente sempre aplicar `Errored{SessionID: <sessionID ou o id já conhecido pelo caller>}` quando o Runner não viu NADA no stream, deixando o Applier decidir se isso é uma transição válida).
3. Regressão: teste de fixture com um `Target.Start` fake cujo processo sai imediatamente sem emitir nada no stdout, verificando que a sessão retomada acaba em `error` (não fica congelada em `done`) dentro de um teto de tempo razoável.

`[relacionado a SEC-107]`

## SEC-107 — `Launcher.SendText`/`Reply` podem chamar `SendUserMessage` num Handle one-shot (Codex) sem stdin, causando panic
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (a plataforma de execução compartilhada não expõe a capacidade "aceita input pelo stdin" ao código que decide se deve escrever nele)
**Localização:** `hub/internal/launcher/launcher.go:632-653` (`SendText`, branch `if live`, linha 645: `h.SendUserMessage(text)`), `hub/internal/adapter/agent/handle.go:121-131` (`WriteJSON`, linha 129: `h.Stdin.Write(b)`), `hub/internal/adapter/codex/target.go:144-157` (`startCodex`, linha 148: `cmd.Stdin = nil` — todo Handle do Codex nasce com `Stdin == nil`), `app/CutuqueApp/SessionDetailView.swift:352-358` (`isLive`/`canSend` não distinguem agente, permitindo o toque de enviar/quick-reply durante `state == running` de qualquer agente)
**Detectado:** 2026-07-06 | **Status:** open

**Descrição:**
O Codex roda em modo one-shot (`codex exec`): cada `Handle` é criado com `Stdin == nil` (`startCodex`, `codex/target.go:144-157` — comentário explícito: "Codex é one-shot: o prompt já está no argumento; stdin fechado evita que ele pendure esperando input"). Isso é correto para o Start inicial, mas a plataforma compartilhada (`agent.Handle`) não expõe essa característica ("este Handle aceita `SendUserMessage`?") a quem decide se deve escrevê-lo — e `Launcher.SendText` (usada tanto para digitação livre quanto, via `Reply`, para respostas de ação de push) decide unicamente pela presença de um handle "vivo" em `l.handles[id]`, sem checar o agente:

```go
if live {
    l.eng.Apply(event.Event{... Kind: event.KindUser, Data: text ...}) // eco APLICADO primeiro
    if err := h.SendUserMessage(text); err != nil { ... }             // panic aqui p/ Codex
    ...
}
```

`h.SendUserMessage` → `h.WriteJSON` → `h.Stdin.Write(b)`, e como `h.Stdin` é uma interface `io.WriteCloser` nula (não um ponteiro concreto nulo), chamar `.Write` nela é um nil pointer dereference — panic em tempo de execução.

**Isto não é uma corrida rara**: uma sessão Codex fica em `state == running` do `thread.started` até o `turn.completed` — ou seja, durante TODO o tempo de inferência do modelo (tipicamente vários segundos). `handles[id]` é populado exatamente nesse mesmo intervalo (`launchApplier.Apply`, `SessionStarted` → `setHandle`). E o app (`SessionDetailView.swift`) **habilita ativamente** o envio de texto e as respostas rápidas (quick replies) sempre que `isLive` (`state == .running || state == .needsYou`) é verdadeiro, sem qualquer exceção para o Codex (`canSend`/`isLive`, linhas 352-358) — inclusive o placeholder do campo de texto diz "Responda ao agente…" justamente quando `isLive`. Ou seja: **o próprio app convida a usuária a fazer exatamente a ação que derruba a request no hub**, sempre que ela manda uma segunda mensagem/toca um quick-reply enquanto um turno do Codex ainda está em andamento. `Reply` (usada pela ação rápida de push) tem o mesmo problema: como o Codex nunca tem `Pane` (não integra com tmux), `Reply` sempre cai em `SendText` para sessões Codex.

Efeitos concretos quando isso acontece:
1. O eco (`OutputChunk kind=user`) já foi aplicado ANTES da escrita falhar — a mensagem da usuária aparece na conversa como "enviada" mesmo tendo sido descartada sem nunca chegar ao Codex. Isso é enganoso: não há nenhum sinal de que a segunda mensagem se perdeu.
2. O `net/http` padrão do Go recupera o panic por conexão (não derruba o processo do hub inteiro), mas a conexão HTTP é abortada sem nenhuma resposta JSON estruturada — o app recebe um erro de rede genérico em vez do 409 `no_live_session` que já existe para exatamente este cenário (ver abaixo).
3. `launcher.ErrNoHandle` (`launcher.go:37`) já está definido, já está mapeado para `409 no_live_session` em `InputHandler` (`server/launch.go:529`), e já tem um teste garantindo esse mapeamento (`launch_test.go:276`) — mas **nada em `SendText` jamais o retorna**. A peça que resolveria isto de forma limpa já existe parcialmente, só não está conectada a uma checagem de capacidade do Handle.

Nenhum teste de `launcher_test.go` exercita esse caminho: o fake `scriptTarget` usado em todos os testes de `SendText`/`resume` sempre cria um `Handle` com `Stdin` de verdade (um `io.Pipe`), simulando só o comportamento bidirecional do Claude — não existe nenhum fake que produza um Handle `Stdin == nil` para exercitar `SendText` num handle "vivo" sem canal de escrita.

**Fix recomendado:**
1. Dar ao `Handle`/`Target` uma forma explícita de expressar "aceita input pelo stdin" (ex.: `func (h *Handle) AcceptsInput() bool { return h.Stdin != nil }`, ou um método no próprio `Target`, já que é uma propriedade do agente, não uma decisão por instância). `SendText`, antes de chamar `h.SendUserMessage`, checa essa capacidade; se `false`, devolve `launcher.ErrNoHandle` (o mapeamento HTTP para 409 já existe) em vez de tentar escrever.
2. Não aplicar o eco (`OutputChunk kind=user`) antes de confirmar que a mensagem tem como ser entregue — ou, no mínimo, para agentes sem canal vivo aceitando input nesse instante, aplicar o eco só DEPOIS que `SendText` decidir que vai de fato entregá-la (seja pelo stdin vivo, seja via `resume`).
3. No app, gate `canSend`/quick replies para não convidar a ação nesse estado específico (ex.: desabilitar enquanto `agent == "codex" && state == .running`, ou — melhor — o hub devolver algum sinal de "aceita input agora" que o app usa para desenhar o estado do botão, em vez de assumir que todo estado `running`/`needsYou` aceita texto).
4. Regressão: um teste de `launcher_test.go` com um fake Target cujo `Handle.Stdin` é nil (espelhando `codex.startCodex`), verificando que `SendText` num handle "vivo" desse tipo devolve `ErrNoHandle` em vez de propagar/panicar.

## SEC-106 — `Engine.ensureRunning` reabre variante silenciosa da corrida de criação de sessão (residual do SEC-103)
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (falha de confiabilidade de um controle de segurança/aprovação, não injeção clássica)
**Localização:** `hub/internal/engine/engine.go:86-102` (`ensureRunning`, branch de criação: `Get` + `Add` bruto, não `AddIfAbsent`)
**Detectado:** 2026-07-03 | **Status:** RESOLVIDO (2026-07-06, confirmado por leitura de código nesta leva — ver nota)

**Nota de verificação (2026-07-06, leva do adapter Codex):** `Engine.ensureRunning` (`engine.go:86-119`) já usa `e.reg.AddIfAbsent(...)` no branch de criação (não mais `Get`+`Add` bruto). Fora de escopo desta leva (não foi tocado no diff revisado), mas confirmado corrigido por leitura direta do arquivo atual — fechando este achado.

**Descrição (histórico, mantida para contexto):**
O fix do SEC-103/da 4ª ocorrência do padrão `reivindicação-não-atômica-de-recurso-compartilhado` migrou `Engine.EnsureRegistered` para `Registry.AddIfAllowed` (atômico), mas `Engine.ensureRunning` — o caminho IRMÃO que também cria sessão do zero, usado tanto pelo `Runner` quanto pelo dispatch de hook `SessionStart`/`UserPromptSubmit` via `Apply` — não tinha sido migrado junto. Seu branch de criação fazia `e.reg.Get(ev.SessionID)` seguido de `e.reg.Add(session.Session{...})` bruto como duas aquisições de lock separadas.

**Fix aplicado:** `ensureRunning` agora usa `e.reg.AddIfAbsent(novaSessao)`; se `added==false`, cai no mesmo bloco de reconciliação (`Reclaim`/`UpdateState`/`SetPane`) já existente para o caso "já existia" — exatamente o fix recomendado.

`[→ review/patterns.md#reivindicação-não-atômica-de-recurso-compartilhado]`

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

**Ressalva (2026-07-03):** o MESMO branch de `ensureRunning` que chama `Reclaim` (usado quando a sessão JÁ existe) está correto; mas o branch IRMÃO — criação de sessão DO ZERO, quando nenhum dos dois lados jamais viu o id antes — continuava fazendo `Get`+`Add` bruto, não `AddIfAbsent`, reabrindo uma variante mais estreita (e mais silenciosa) da mesma classe de corrida. Rastreada separadamente como **SEC-106** (não reabre este ticket porque o cenário aqui descrito — sessão já registrada por um lado, reclamada pelo outro — está genuinamente fechado; o residual era uma janela de timing distinta, na criação concorrente do zero). SEC-106 confirmado RESOLVIDO em 2026-07-06.

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

**Verificação de não-regressão (2026-07-06, leva do adapter Codex):**
`codex/target.go` (`remoteCodexCommand`/`codexArgs`) reusa o MESMO idioma estrutural (`bash -lc 'exec "$0" "$@"' <argv...>`, cada arg individualmente single-quoted via `agent.SingleQuote`, um único nível de shell) — confirmado por leitura de código, é literalmente o mesmo padrão do `claudecode`, agora extraído para `agent.SingleQuote`/reusado por ambos. `resumeID` que chega em `codexArgs` é sempre `""`, um id já validado por `sessionIDPattern` (`Adopt`), ou um `thread_id` gerado pelo próprio processo `codex` (nunca input direto de cliente sem validação prévia). `sandbox`/`effort` só entram em `-c chave="valor"` depois de passar por allowlists estritas (`validSandbox`/`validEffort`); `model` passa por um regex estrito (`modelNamePattern`) antes de virar `-m <model>`, e mesmo se o regex falhasse, o valor ainda seria isolado corretamente pelo quoting estrutural por-argumento. **SEC-101 não regrediu; nenhuma injeção nova encontrada no adapter do Codex.**

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
