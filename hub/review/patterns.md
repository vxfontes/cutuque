# Padrões recorrentes — cutuque/hub

Alimentado quando um padrão aparece pela 2ª vez ou mais.

## recurso-de-longa-duração-sem-cancelamento
**Categoria:** design | correctness
**Frequência:** 3x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02 (Fase 4)
**Descrição:** Goroutines/conexões de vida longa criadas sem um caminho explícito de cancelamento/timeout, ou com o caminho existente mas nunca acionado:
1. `internal/server/seed.go` (`seedDriver.run(seedInterval, nil)` — canal `stop` nil, roda para sempre).
2. `internal/server/ws.go` — loop de escrita do WebSocket dependia só de `ctx.Done()` vindo de `CloseRead`, sem ping/pong nem timeout de escrita.
3. `internal/notifier/notifier.go` (`Notifier.Start`/`loop`, Fase 4) — diferente dos dois casos acima, aqui o caminho de cancelamento EXISTE e está corretamente implementado (`Notifier.Close()`: unsubscribe idempotente + `wg.Wait()` esperando o fan-out em voo), mas `cmd/hub/main.go` nunca o chama. Mesma causa raiz dos dois primeiros: ausência de qualquer graceful shutdown (`signal.NotifyContext`/`srv.Shutdown`) no processo do hub como um todo.
**Recomendação:** Toda goroutine/conexão de vida longa deve ter (a) um caminho de cancelamento acionável (contexto com timeout, canal `stop` real, ou sinal de shutdown do processo) e (b) para conexões de rede, um heartbeat (ping/pong) com timeout de escrita curto. O caso 3 mostra que ter o método `Close()` certo não basta — falta um `main.go` que efetivamente monte um `signal.NotifyContext` e chame `Close()`/`srv.Shutdown()` em cascata em todos os componentes de vida longa (seed driver, WS, Notifier) no encerramento do processo. Vale resolver isso de uma vez só (um "shutdown orchestrator" central) em vez de corrigir componente por componente.
**Status:** o caso do WS (`ws.go`) foi corrigido em 2026-07-02 (ping periódico + timeout de escrita). Os casos de `seed.go` e `Notifier` seguem abertos (aceitos como dívida dev-only até a Fase 5 tratar de graceful shutdown do processo como um todo).

## invariante-declarada-mas-não-garantida
**Categoria:** security | design
**Frequência:** 3x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Um comentário/docstring declara uma regra de negócio, mas o código não a garante:
1. `internal/config/config.go` ("em prod o token é obrigatório e nunca recebe default") — se `CUTUQUE_TOKEN` não fosse setado em prod, `Token` ficava `""` silenciosamente e a auth aceitava qualquer request. **Corrigido em 2026-07-02** (fail-fast no boot + `validToken` nunca aceita configured=="").
2. `internal/session/session.go`: `State` é uma string aberta com 5 constantes documentadas, mas `Registry.UpdateState` não valida contra elas — qualquer string passa. **Ainda aberto.**
3. `internal/engine/engine.go` declara em doc: "[Engine] é a única peça que escreve o estado das sessões" — mas `internal/adapter/claudecode/runner.go` (`registerSession`) escrevia direto no `*registry.Registry` para criar a sessão com metadados (machine/agent/title), contornando o Engine inteiramente. **Corrigido em 2026-07-02** (Fase 2, commit `82ef9a8`): metadados agora viajam no evento `session_started` e o Engine passa a criar a sessão via `ensureRunning`.
**Recomendação:** Quando um comentário descreve um invariante ("X é obrigatório", "Y nunca pode ser Z", "só o componente A escreve o estado"), adicionar a validação/estrutura correspondente no código (fail-fast/erro, ou simplesmente não expor a via de bypass) e um teste que prove a falha no caso inválido — não confiar só no comentário. Para `State`: considerar um `func (s State) Valid() bool` usado em `UpdateState` (item 2 ainda pendente).

## weak-self-fora-do-loop-em-task-de-stream
**Categoria:** correctness (Swift/iOS)
**Frequência:** 2x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Em `app/CutuqueApp/SessionListView.swift` (`SessionListViewModel.startLiveUpdates`) e `SessionDetailView.swift` (`SessionDetailViewModel.startLiveUpdates`), o padrão `Task { [weak self] in guard let self else { return }; for await x in self.api.liveUpdates() { ... } }` desembrulha `self` UMA vez, fora do loop. Como o `for await` pode rodar indefinidamente (stream só termina quando a própria Task é cancelada), a closure retém `self` fortemente durante toda a vida do loop, formando um ciclo de retenção. **Corrigido em 2026-07-02** (commit `dded81e`) nos dois ViewModels; confirmado ainda correto na Fase 4 (nenhuma reintrodução).
**Recomendação:** Mover o `guard let self` para DENTRO do corpo do loop, reavaliado a cada iteração — padrão já aplicado corretamente e replicável para qualquer novo consumidor de `liveUpdates()`.

## reivindicação-não-atômica-de-recurso-compartilhado
**Categoria:** correctness | concurrency
**Frequência:** 2x | **Primeira vez:** 2026-07-02 (Fase 3) | **Última:** 2026-07-02 (Fase 3)
**Descrição:** Duas goroutines podem "ler para decidir, depois agir" sobre o mesmo recurso mutável sem seção crítica única que cubra check+ação, permitindo que ambas passem na validação e ambas ajam sobre o mesmo recurso:
1. `internal/adapter/claudecode/target.go` (`Handle.Close`): concorrência entre timeout e término natural do `runner.Run`, ambos chamando `Close()`. **Corrigido** (commit `df54e67`, `sync.Once`).
2. `internal/launcher/launcher.go` (`respond`, usado por `Approve`/`Deny`): claim não-atômico de `pending`/`handles`. **Corrigido** (commit `7f4a87e`, claim atômico dentro do lock).
**Recomendação:** Sempre que um recurso compartilhado precisa ser "consumido uma única vez" por request concorrentes, a reivindicação deve ser a MESMA operação atômica que a leitura de elegibilidade. Verificado na Fase 4 (`apns.Client.bearerToken`, `devices.Store`, `notifier.states`) que o padrão NÃO reapareceu: o cache do JWT faz check+reassinatura dentro do mesmo lock, e o `Notifier` é single-consumer por design (só uma goroutine lê `sub.C`), então não há concorrência real sobre `states` apesar do mutex defensivo.

## registry-broadcast-de-melhor-esforço-sem-garantia-de-entrega
**Categoria:** correctness | design
**Frequência:** 2x | **Primeira vez:** 2026-07-02 (Fase 1, como nota não-bloqueante) | **Última:** 2026-07-02 (Fase 4)
**Descrição:** `Registry.broadcast` (`internal/registry/registry.go:153-162`) é deliberadamente não-bloqueante: se o buffer do subscriber (32, `subBuffer`) estiver cheio, o evento é descartado (`select`/`default`) para nunca travar o Registry. Isso é a escolha certa para não deixar um subscriber lento travar o sistema inteiro, mas o efeito colateral do descarte varia por consumidor:
1. **Fase 1 (WS):** um subscriber lento fica temporariamente desatualizado até o próximo evento ou reconexão (que traz um snapshot completo) — degradação suave.
2. **Fase 4 (Notifier):** o Notifier depende de um contrato de DOIS broadcasts sequenciais para disparar o push de `needs_you` (`UpdateState` sem `PendingPrompt`, depois `SetPendingPrompt` com o texto — `notifier.go:94-99`). Se o SEGUNDO broadcast for descartado numa rajada de eventos, o Notifier nunca vê o `PendingPrompt`, e a transição fica **permanentemente invisível** — o push mais importante da fase (o "cutucão" que pede aprovação) simplesmente não dispara, sem log de erro em lugar nenhum. Diferente do caso 1, aqui não há "próxima chance": o estado interno do Notifier (`n.states`) já não reflete mais a realidade e só se realinha na PRÓXIMA transição real (ex. quando a sessão terminar), mascarando a perda.
**Recomendação:** Para consumidores internos onde uma perda silenciosa tem consequência de produto grave (não só UI desatualizada), considerar um canal com buffer maior e/ou sem descarte (bloqueante com timeout curto, ou uma fila persistente pequena) — mantendo o comportamento lossy só para consumidores de UI que já têm mecanismo de recuperação (snapshot). Alternativa mais barata: o Notifier logar quando percebe uma transição "pulada" (ex. estado observado não é um sucessor válido do último estado conhecido) para pelo menos tornar o problema visível em vez de silencioso. Risco prático baixo hoje dado o volume de um hub pessoal (exige >32 eventos não consumidos em rajada), mas registrado por ser a 2ª manifestação do mesmo padrão de fundo com severidade crescente.
