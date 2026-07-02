# Padrões recorrentes — cutuque/hub

Alimentado quando um padrão aparece pela 2ª vez ou mais.

## recurso-de-longa-duração-sem-cancelamento
**Categoria:** design | correctness
**Frequência:** 2x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Goroutines/conexões de vida longa criadas sem um caminho explícito de cancelamento/timeout. Visto em `internal/server/seed.go` (`seedDriver.run(seedInterval, nil)` — canal `stop` nil, roda para sempre) e em `internal/server/ws.go` (loop de escrita do WebSocket depende só de `ctx.Done()` vindo de `CloseRead`, sem ping/pong nem timeout de escrita — uma conexão travada sem FIN/RST nunca libera a goroutine, a subscription no Registry nem o buffer do canal).
**Recomendação:** Toda goroutine/conexão de vida longa deve ter (a) um caminho de cancelamento acionável (contexto com timeout, canal `stop` real, ou sinal de shutdown do processo) e (b) para conexões de rede, um heartbeat (ping/pong) com timeout de escrita curto (ex. `context.WithTimeout` por mensagem) para detectar peers mortos que não fecham a conexão de forma limpa — cenário comum no caso de uso real do hub (app mobile em background, troca de rede, laptop dormindo).
**Status:** o caso do WS (`ws.go`) foi corrigido em 2026-07-02 (ping periódico + timeout de escrita, ver log). O caso do `seed.go` segue aberto (aceito como dívida dev-only).

## invariante-declarada-mas-não-garantida
**Categoria:** security | design
**Frequência:** 3x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Um comentário/docstring declara uma regra de negócio, mas o código não a garante:
1. `internal/config/config.go` ("em prod o token é obrigatório e nunca recebe default") — se `CUTUQUE_TOKEN` não fosse setado em prod, `Token` ficava `""` silenciosamente e a auth aceitava qualquer request. **Corrigido em 2026-07-02** (fail-fast no boot + `validToken` nunca aceita configured=="").
2. `internal/session/session.go`: `State` é uma string aberta com 5 constantes documentadas, mas `Registry.UpdateState` não valida contra elas — qualquer string passa. **Ainda aberto.**
3. `internal/engine/engine.go` declara em doc: "[Engine] é a única peça que escreve o estado das sessões" — mas `internal/adapter/claudecode/runner.go` (`registerSession`) escreve direto no `*registry.Registry` para criar a sessão com metadados (machine/agent/title), contornando o Engine inteiramente. Efeito colateral concreto: o ramo de criação de `Engine.ensureRunning` é código morto no fluxo real (só é exercitado por teste unitário isolado). **Ainda aberto** — ver log 2026-07-02 (Fase 2).
**Recomendação:** Quando um comentário descreve um invariante ("X é obrigatório", "Y nunca pode ser Z", "só o componente A escreve o estado"), adicionar a validação/estrutura correspondente no código (fail-fast/erro, ou simplesmente não expor a via de bypass) e um teste que prove a falha no caso inválido — não confiar só no comentário. Para `State`: considerar um `func (s State) Valid() bool` usado em `UpdateState`. Para o Engine: `event.Event` precisa carregar os metadados que os adapters têm (machine/agent/title) para que a criação de sessão também passe pelo Engine — ver fix recomendado no log de 2026-07-02 (Fase 2).

## weak-self-fora-do-loop-em-task-de-stream
**Categoria:** correctness (Swift/iOS)
**Frequência:** 2x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Em `app/CutuqueApp/SessionListView.swift` (`SessionListViewModel.startLiveUpdates`) e `SessionDetailView.swift` (`SessionDetailViewModel.startLiveUpdates`), o padrão `Task { [weak self] in guard let self else { return }; for await x in self.api.liveUpdates() { ... } }` desembrulha `self` UMA vez, fora do loop. Como o `for await` pode rodar indefinidamente (stream só termina quando a própria Task é cancelada), a closure retém `self` fortemente durante toda a vida do loop. Combinado com o ViewModel guardar essa Task numa property (`self.liveTask = task`), forma-se um ciclo de retenção (`self -> liveTask -> closure -> self`) que só quebra se algo externo ao ciclo chamar `.cancel()` (hoje, só `onDisappear`). Se `onDisappear` não disparar por qualquer razão, ViewModel + Task + conexão WebSocket vazam para sempre.
**Recomendação:** Mover o `guard let self` para DENTRO do corpo do loop, reavaliado a cada iteração (`for await message in stream { guard let self else { break }; ... }`), obtendo o stream antes do loop via `self?.api.liveUpdates()` sem reter `self` além do necessário. Assim `self` só fica retido durante o processamento pontual de cada mensagem, nunca durante a vida inteira do stream — eliminando o ciclo. Considerar extrair esse padrão de "live stream com reconexão" para um helper único reusável, já que hoje está duplicado nos dois ViewModels.

## reivindicação-não-atômica-de-recurso-compartilhado
**Categoria:** correctness | concurrency
**Frequência:** 2x | **Primeira vez:** 2026-07-02 (Fase 3) | **Última:** 2026-07-02
**Descrição:** Duas goroutines podem "ler para decidir, depois agir" sobre o mesmo recurso mutável sem seção crítica única que cubra check+ação, permitindo que ambas passem na validação e ambas ajam sobre o mesmo recurso:
1. `internal/adapter/claudecode/target.go` (`Handle.Close`): quando `Launcher.Launch` estoura o timeout, a goroutine chamadora (`select`/`time.After`) e a goroutine de fundo (após `runner.Run` retornar) chamam `handle.Close()` concorrentemente. Para um `Target` real (`closer = cmd.Wait`), isso é uma **data race comprovada** dentro do próprio `os/exec` (reproduzido com `-race` fora do código revisado; nenhum teste do repo exercita esse caminho porque os fakes de teste usam `io.Pipe` sem `closer`).
2. `internal/launcher/launcher.go` (`respond`, usado por `Approve`/`Deny`): lê `l.pending[id]`/`l.handles[id]` sob lock, solta o lock, escreve no processo, e só then limpa `l.pending` — sem CAS/claim atômico. Duas chamadas concorrentes (double-tap, retry de rede, approve+deny em corrida) podem ambas passar na validação e ambas escrever um `control_response` para o mesmo `request_id`.
**Recomendação:** Sempre que um recurso compartilhado precisa ser "consumido uma única vez" por request concorrentes, a reivindicação (marcar como já tomado / já fechado) deve ser a MESMA operação atômica que a leitura de elegibilidade — dentro do mesmo lock (ex.: `read+delete` do mapa sob `Lock()`), ou via `sync.Once` para idempotência de ciclo de vida (`Close`). Nunca separar "verifiquei que posso agir" de "marquei que já agi" em duas seções críticas distintas.
