# Achados de segurança — cutuque/hub

## SEC-001 — Token vazio em prod desativa a autenticação inteira
**Severidade:** R1 | **OWASP:** A07:2021 (Identification and Authentication Failures) / A05:2021 (Security Misconfiguration)
**Localização:** `internal/config/config.go:53-56` (Token fica `""` se `CUTUQUE_TOKEN` não setado em prod) + `internal/server/auth.go:18` (compara com `!=`) + `internal/server/server.go:20-24` (wiring) + `cmd/hub/main.go` (nenhum guard no boot)
**Detectado:** 2026-07-02 | **Status:** open
**Descrição:** `config.Load()` só aplica o default `"dev-token"` quando `env == "dev"`. Em prod, se `CUTUQUE_TOKEN` não estiver setado, `cfg.Token` fica `""`. `requireAuth` faz `tokenFromRequest(r) != token`; quando não há header `Authorization` nem `?token=` na request, `tokenFromRequest` retorna `""` por padrão (`auth.go:37`). Resultado: `"" != ""` é falso → a request passa sem NENHUM token, para `/sessions`, `/ws` e (se `Env` fosse dev por engano) `/dev/seed`. O comentário em `config.go:15-16` afirma "em prod o token é obrigatório e nunca recebe default", mas nada no código impede o processo de subir com token vazio nem impede a auth de aceitar ausência de token quando o token configurado é vazio. Isso expõe todas as sessões (nomes de máquina, agente, título da tarefa, estado) para qualquer host que alcance o endereço Tailscale, silenciosamente — sem crash, sem log de erro, sem indicação de que a auth está desligada.
**Fix recomendado:**
1. Fail-fast no boot: em `cmd/hub/main.go` (ou dentro de `config.Load`/uma função `Validate`), se `cfg.Env == "prod" && cfg.Token == ""`, logar erro e `os.Exit(1)` antes de `ListenAndServe`.
2. Defesa em profundidade em `requireAuth`: se o `token` configurado for `""`, negar sempre (401) independentemente do que vier na request, em vez de comparar igualdade — um token vazio nunca deveria ser "válido".
3. Adicionar teste que cubra o cenário: `Router` com `cfg.Token == ""` deve rejeitar uma request sem header/query token (hoje não existe esse teste; `TestLoadProdEmptyTokenStaysEmpty` só verifica o valor de `Token`, não o comportamento de auth resultante).

## SEC-002 — Comparação de token não é constant-time
**Severidade:** R3 | **OWASP:** A02:2021 (Cryptographic Failures) — timing side-channel
**Localização:** `internal/server/auth.go:18`
**Detectado:** 2026-07-02 | **Status:** open
**Descrição:** `tokenFromRequest(r) != token` usa comparação padrão de string do Go, que retorna assim que encontra o primeiro byte diferente (ou por diferença de tamanho). Em teoria vaza um sinal de timing sobre quantos bytes do prefixo do token estão corretos. Exploração prática exige muitas amostras e uma rede com pouco jitter; sobre Tailscale/LAN isso é mais viável do que pela internet pública, mas ainda seria necessário um volume grande de tentativas.
**Fix recomendado:** Usar `crypto/subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1`, cuidando de tratar tamanhos diferentes antes de chamar (a função não normaliza tamanho — comparar `len` primeiro é seguro pois o tamanho do token não costuma ser segredo, só o conteúdo).

## SEC-003 — Token do WebSocket viaja na query string
**Severidade:** R4 | **OWASP:** A09:2021 (Security Logging and Monitoring Failures) / exposição de dado sensível
**Localização:** `internal/server/auth.go:30-38`, uso em `ws.go`
**Detectado:** 2026-07-02 | **Status:** accepted
**Descrição:** Como browsers não permitem setar headers customizados na negociação de WebSocket, o token trafega em `?token=...`. Query strings tendem a vazar por access logs de proxies/load balancers, histórico do navegador e cabeçalho `Referer`. Hoje o hub não tem nenhum middleware de access log, então o risco é latente, não ativo.
**Fix recomendado:** Nenhuma ação imediata necessária (trade-off aceito e documentado no código). Se algum dia for adicionado logging de requests, garantir que a query string seja redigida/mascarada antes de logar, e considerar rotação de token ou token de curta duração específico para upgrade de WS no futuro.
