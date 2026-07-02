# Achados de segurança — cutuque/hub

## SEC-001 — Token vazio em prod desativa a autenticação inteira
**Severidade:** R1 | **OWASP:** A07:2021 (Identification and Authentication Failures) / A05:2021 (Security Misconfiguration)
**Localização:** `internal/config/config.go:53-56` (Token fica `""` se `CUTUQUE_TOKEN` não setado em prod) + `internal/server/auth.go:18` (compara com `!=`) + `internal/server/server.go:20-24` (wiring) + `cmd/hub/main.go` (nenhum guard no boot)
**Detectado:** 2026-07-02 | **Status:** resolved (2026-07-02, commit `8aa0dfa`)
**Descrição:** `config.Load()` só aplica o default `"dev-token"` quando `env == "dev"`. Em prod, se `CUTUQUE_TOKEN` não estiver setado, `cfg.Token` fica `""`. `requireAuth` faz `tokenFromRequest(r) != token`; quando não há header `Authorization` nem `?token=` na request, `tokenFromRequest` retorna `""` por padrão (`auth.go:37`). Resultado: `"" != ""` é falso → a request passa sem NENHUM token, para `/sessions`, `/ws` e (se `Env` fosse dev por engano) `/dev/seed`. O comentário em `config.go:15-16` afirma "em prod o token é obrigatório e nunca recebe default", mas nada no código impede o processo de subir com token vazio nem impede a auth de aceitar ausência de token quando o token configurado é vazio. Isso expõe todas as sessões (nomes de máquina, agente, título da tarefa, estado) para qualquer host que alcance o endereço Tailscale, silenciosamente — sem crash, sem log de erro, sem indicação de que a auth está desligada.
**Fix aplicado (verificado em 2026-07-02):**
1. Fail-fast no boot: `cmd/hub/main.go:16-19` — `os.Exit(1)` se `cfg.Env == "prod" && cfg.Token == ""`, com log de erro antes.
2. Defesa em profundidade: `auth.go` (`validToken`) — token configurado `""` nunca é válido, independente do que vier na request.
3. Teste (`auth_test.go`) cobrindo o comportamento de auth resultante, não só o valor de config.

## SEC-002 — Comparação de token não é constant-time
**Severidade:** R3 | **OWASP:** A02:2021 (Cryptographic Failures) — timing side-channel
**Localização:** `internal/server/auth.go:18`
**Detectado:** 2026-07-02 | **Status:** resolved (2026-07-02, commit `8aa0dfa`)
**Descrição:** `tokenFromRequest(r) != token` usava comparação padrão de string do Go, que retorna assim que encontra o primeiro byte diferente (ou por diferença de tamanho). Em teoria vaza um sinal de timing sobre quantos bytes do prefixo do token estão corretos.
**Fix aplicado (verificado em 2026-07-02):** `validToken` agora usa `crypto/subtle.ConstantTimeCompare([]byte(configured), []byte(provided)) == 1`, com o caso `configured == ""` tratado antes (short-circuit seguro, pois o tamanho do token não é segredo).

## SEC-003 — Token do WebSocket viaja na query string
**Severidade:** R4 | **OWASP:** A09:2021 (Security Logging and Monitoring Failures) / exposição de dado sensível
**Localização:** `internal/server/auth.go:30-38`, uso em `ws.go`
**Detectado:** 2026-07-02 | **Status:** accepted
**Descrição:** Como browsers não permitem setar headers customizados na negociação de WebSocket, o token trafega em `?token=...`. Query strings tendem a vazar por access logs de proxies/load balancers, histórico do navegador e cabeçalho `Referer`. Hoje o hub não tem nenhum middleware de access log, então o risco é latente, não ativo.
**Fix recomendado:** Nenhuma ação imediata necessária (trade-off aceito e documentado no código). Se algum dia for adicionado logging de requests, garantir que a query string seja redigida/mascarada antes de logar, e considerar rotação de token ou token de curta duração específico para upgrade de WS no futuro.

## SEC-004 — POST /hooks/claude sem limite de tamanho de body (DoS)
**Severidade:** R3 | **OWASP:** A04:2021 (Insecure Design) / API4:2023 (Unrestricted Resource Consumption)
**Localização:** `internal/server/hooks.go:28-29`
**Detectado:** 2026-07-02 | **Status:** resolved (2026-07-02, commit `79aca41`, `MaxBytesReader` de 64KB aplicado; `internal/server/launch.go` replica o mesmo padrão para os novos endpoints de comando)
**Descrição:** `HookHandler` faz `json.NewDecoder(r.Body).Decode(&p)` sem nenhum `http.MaxBytesReader` ou limite de tamanho de corpo. É o único endpoint de escrita (POST) do hub e já está roteado em produção (`server.go:28`, atrás de auth). Qualquer chamador com o token válido — inclusive um token vazado via SEC-003, ou um script/hook mal configurado — pode enviar um body arbitrariamente grande e forçar o hub (processo único, sem isolamento) a bufferizar tudo em memória antes de rejeitar. Mesmo autenticado, é uma superfície de DoS trivial e barata de fechar.
**Fix recomendado:** `r.Body = http.MaxBytesReader(w, r.Body, 64*1024)` (ou limite equivalente) antes do `Decode`, respondendo 400/413 quando excedido. Considerar aplicar um limite default para qualquer POST futuro do hub (ex. middleware genérico), não só neste handler.

## SEC-005 — Hook aceita session_id de qualquer sessão conhecida sem checagem de posse
**Severidade:** R4 | **OWASP:** A01:2021 (Broken Access Control) — mitigado pelo modelo de confiança documentado
**Localização:** `internal/server/hooks.go:26-41`
**Detectado:** 2026-07-02 | **Status:** accepted
**Descrição:** `POST /hooks/claude` só exige o token bearer compartilhado; não há nenhuma checagem de que quem está mandando o hook é realmente a máquina/processo dono daquele `session_id`. Um payload forjado (mas com token válido) pode forçar qualquer sessão conhecida para `needs_you` ou `done` arbitrariamente. Isso é consistente com o modelo de confiança documentado (token único por device pessoal, tráfego só dentro da Tailscale, sem multi-tenant) — a mesma fronteira de confiança do SEC-003 — mas agrava o impacto de um eventual vazamento de token: não seria só leitura de estado, mas também injeção de transições falsas (ex.: silenciar um "needs_you" real marcando a sessão como `done`).
**Fix recomendado:** Nenhuma ação imediata dado o modelo de uso pessoal atual. Se o hub algum dia suportar múltiplos usuários/devices com tokens diferentes, associar sessão a um token/device de origem e validar posse antes de aplicar o hook.

## SEC-006 — Processo `claude` herda todo o ambiente do hub (token e futuros segredos)
**Severidade:** R1 | **OWASP:** A05:2021 (Security Misconfiguration) / A01:2021 (Broken Access Control por vazamento de credencial)
**Localização:** `internal/adapter/claudecode/target.go:134-152` (`LocalTarget.Start`, `exec.CommandContext` sem `cmd.Env`)
**Detectado:** 2026-07-02 | **Status:** open
**Descrição:** `LocalTarget.Start` cria o `exec.Cmd` sem definir `cmd.Env`, então o processo `claude` herda **todo** o ambiente do hub — inclusive `CUTUQUE_TOKEN`, o único segredo que protege toda a superfície HTTP/WS do hub (launch, approve/deny, leitura de todas as sessões). O próprio docs/10 (armadilha #2) documenta que comandos considerados "seguros" (ex. `echo`) executam **sem passar pelo `control_request`** — ou seja, sem chance de veto do hub. Isso significa que um `env`/`printenv` (ou qualquer comando na allowlist do usuário, ou induzido por prompt injection a partir de conteúdo externo que o agente processe) pode capturar `CUTUQUE_TOKEN` e fazê-lo aparecer no `tool_result` → `output_chunk` normal, ou ser exfiltrado por um comando de rede subsequente — sem nunca passar pelo gate de aprovação. Docs/05 já prevê que credenciais futuras (APNs `.p8`) "ficam só no hub" — se esse segredo também virar env var do processo hub, o mesmo vazamento se aplica a ele.
**Fix recomendado:** Construir um `cmd.Env` explícito (allowlist) em vez de herdar `os.Environ()` — só o necessário para o `claude` CLI rodar (`PATH`, `HOME`, locale, e a credencial de API do próprio Claude Code se for via env). Nunca deixar `CUTUQUE_TOKEN`/segredos do hub entrarem no env do processo filho. Vale um teste que rode `LocalTarget.Start` e assert que uma env var sentinela setada no processo do hub NÃO aparece no ambiente do filho.

## SEC-007 — Sem limite de sessões/processos concorrentes lançados
**Severidade:** R3 | **OWASP:** API4:2023 (Unrestricted Resource Consumption)
**Localização:** `internal/launcher/launcher.go:83-121` (`Launch`, sem checagem de `len(handles)` ou qualquer teto)
**Detectado:** 2026-07-02 | **Status:** open
**Descrição:** Cada `POST /sessions` autenticado spawna um processo `claude` real (custo de API real, não só CPU/memória local). Não há nenhum teto de sessões/processos vivos simultâneos — um cliente com bug (retry em loop), um double-tap sem debounce eficaz, ou um token vazado (SEC-003) pode disparar lançamentos ilimitados, e cada um custa dinheiro de verdade além de recursos do host. Diferente das Fases 1/2 (sessões só eram metadado), a Fase 3 introduz esse custo real pela primeira vez.
**Fix recomendado:** `Launcher` rejeitar `Launch` acima de um teto configurável (ex. 5-10 para uma máquina pessoal) com um erro tipado (`ErrTooManyLaunches` → 429/503), contando `len(l.handles)` sob o mesmo mutex já existente.
