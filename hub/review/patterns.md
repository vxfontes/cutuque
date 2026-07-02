# Padrões recorrentes — cutuque/hub

Alimentado quando um padrão aparece pela 2ª vez ou mais.

## recurso-de-longa-duração-sem-cancelamento
**Categoria:** design | correctness
**Frequência:** 2x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Goroutines/conexões de vida longa criadas sem um caminho explícito de cancelamento/timeout. Visto em `internal/server/seed.go` (`seedDriver.run(seedInterval, nil)` — canal `stop` nil, roda para sempre) e em `internal/server/ws.go` (loop de escrita do WebSocket depende só de `ctx.Done()` vindo de `CloseRead`, sem ping/pong nem timeout de escrita — uma conexão travada sem FIN/RST nunca libera a goroutine, a subscription no Registry nem o buffer do canal).
**Recomendação:** Toda goroutine/conexão de vida longa deve ter (a) um caminho de cancelamento acionável (contexto com timeout, canal `stop` real, ou sinal de shutdown do processo) e (b) para conexões de rede, um heartbeat (ping/pong) com timeout de escrita curto (ex. `context.WithTimeout` por mensagem) para detectar peers mortos que não fecham a conexão de forma limpa — cenário comum no caso de uso real do hub (app mobile em background, troca de rede, laptop dormindo).

## invariante-declarada-mas-não-garantida
**Categoria:** security | design
**Frequência:** 2x | **Primeira vez:** 2026-07-02 | **Última:** 2026-07-02
**Descrição:** Um comentário/docstring declara uma regra de negócio ("em prod o token é obrigatório e nunca recebe default", `internal/config/config.go:13-16`) mas o código não a garante — se `CUTUQUE_TOKEN` não for setado em prod, `Token` fica `""` silenciosamente e a auth aceita qualquer request. Mesma classe de problema em `internal/session/session.go`: `State` é uma string aberta com 5 constantes documentadas, mas `Registry.UpdateState` não valida contra elas — qualquer string passa.
**Recomendação:** Quando um comentário descreve um invariante ("X é obrigatório", "Y nunca pode ser Z"), adicionar a validação correspondente no código (fail-fast/erro) e um teste que prove a falha no caso inválido — não confiar só no comentário. Para o token: falhar o boot do processo (`log.Fatal`/`panic`) se `Env == "prod" && Token == ""`. Para `State`: considerar um `func (s State) Valid() bool` usado em `UpdateState`.
