# Log de revisões — cutuque/hub

Append-only. Entrada mais recente no topo.

## 2026-07-02 — Fase 1: config, registry, session, server/auth/sessions/ws/seed, cmd/hub
**Risco:** R1 (auth/segurança do hub inteiro; achado crítico em `config`+`auth` permite bypass total de autenticação em prod)
**Escopo:** Revisão completa da Fase 1 do hub: `internal/session`, `internal/registry`, `internal/config`, `internal/server/{auth,server,sessions,ws,seed,health}`, `cmd/hub/main.go`. Leitura de todos os `*_test.go`, `docs/02-arquitetura.md`, `docs/03-modelo-de-estado.md`. Rodado `go vet ./...` e `go test -race ./...` (ambos limpos).

### Bloqueantes
- issue (security, blocking): `CUTUQUE_TOKEN` vazio em prod faz `requireAuth` aceitar qualquer request sem token nenhum — bypass total de auth. [→ security.md#SEC-001]
- issue (blocking): `wsjson.Write` em `ws.go:46,59` sem timeout/keepalive — conexão travada (rede caindo sem FIN/RST, sono do laptop, troca wifi/celular no mobile) vaza goroutine + subscription + buffer indefinidamente, sem forma de o servidor detectar e liberar o recurso.

### Non-bloqueantes
- suggestion (security, non-blocking): comparação de token com `!=` em `auth.go:18` não é constant-time; usar `crypto/subtle.ConstantTimeCompare`. [→ security.md#SEC-002]
- suggestion (non-blocking): `broadcast` com drop-if-full (`registry.go:118-123`) pode deixar um subscriber já conectado permanentemente desatualizado até reconectar; considerar snapshot periódico (heartbeat) somado ao fix de timeout do WS.
- suggestion (non-blocking): `seedDriver.run(seedInterval, nil)` em `seed.go:126` roda para sempre sem forma de parar; consistente com a ausência total de graceful shutdown em `main.go` (sem `signal.NotifyContext`/`srv.Shutdown`). Aceitável para dev-only hoje, mas registrar como dívida.
- suggestion (design, non-blocking): `Registry.UpdateState` aceita qualquer `session.State` sem validar contra os 5 estados conhecidos (`session.go:11-17`); útil ter uma validação central antes da Fase 2 expor uma Command API que recebe estado de fora.
- thought (non-blocking): `broadcast` é chamado fora da seção crítica que fez a mutação (`registry.go:48`, `registry.go:88`), então dois updates concorrentes para o MESMO id podem ser entregues aos subscribers fora de ordem (o registry em si fica correto, mas o stream WS pode mostrar um estado antigo depois de um mais novo). Não é atingível hoje dado o invariante "um escritor por sessão" do doc de arquitetura, mas vale nota para quando a Fase 2 introduzir múltiplos escritores por sessão.
- nitpick (non-blocking): `sessions.go:20-22` checa `sessions == nil`, mas `Registry.List()` sempre retorna slice não-nil (via `make`); código morto, inofensivo.
- nitpick (non-blocking): `http.Server` em `server.go:30-36` só define `ReadHeaderTimeout`; falta `ReadTimeout`/`WriteTimeout`/`IdleTimeout` para requests REST comuns (não afeta a conexão hijacked do WS).
- note (non-blocking): token do WS via `?token=` (`auth.go:37`, justificado no comentário por limitação do browser) é um vetor conhecido de exposição via logs/proxies/histórico; hoje não há nenhum middleware de access log, então o risco é latente — documentar para não introduzir logging de URL completa no futuro. [→ security.md#SEC-003]
- praise: `Registry` está bem desenhado — `broadcast` usa `RLock` e `select/default` (nunca bloqueia), e como `Unsubscribe` exige `Lock` exclusivo, o `RWMutex` garante que `close(sub.ch)` nunca corre concorrente com um `send`, evitando o clássico panic de "send on closed channel". Testado com `-race` incluindo o teste de estresse `TestConcurrentAccessIsRaceFree`.
- praise: a ordem "subscribe antes do snapshot" em `ws.go:38-45` está corretamente justificada em comentário e evita perda de eventos (troca uma perda por, no pior caso, uma duplicata idempotente) — raciocínio de concorrência sólido e documentado.

### Padrões detectados
- `recurso-de-longa-duração-sem-cancelamento` (2x: `seed.go` goroutine do ticker, `ws.go` write loop sem heartbeat/timeout) [→ patterns.md#recurso-de-longa-duração-sem-cancelamento]
- `invariante-declarada-em-comentário-mas-não-garantida-em-código` (2x: `config.go` "em prod o token é obrigatório" sem enforcement; `session.State` como string aberta sem validação em `UpdateState`) [→ patterns.md#invariante-declarada-mas-não-garantida]

### Especialistas envolvidos
- Marcus: revisar o fix do bypass de auth (SEC-001) e o mecanismo de heartbeat/timeout do WebSocket — ambos tocam backend/API crítico.
- Rafael: avaliar se deploy de prod deveria falhar-fast (health/readiness check ou validação de env na infra) quando `CUTUQUE_TOKEN` não está setado, como camada extra de defesa além do código.
