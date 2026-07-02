# 11 — APNs (push / cutucão)

O Notifier do hub envia push via APNs nas transições `→ needs_you`, `→ done` e
`→ error` (docs/03). O payload carrega **só metadados** — nunca código-fonte ou
output da sessão (invariante de segurança, docs/02 e `hub/review/security.md`).

## Credenciais e env

A chave `.p8` mora **só no hub**, em `config/key.p8`, e o diretório `config/` é
gitignored — a credencial **nunca** é versionada nem copiada para o app. As env
vars ficam em `config/apns.env`:

```
CUTUQUE_APNS_KEY_PATH=config/key.p8
CUTUQUE_APNS_KEY_ID=<key id da chave .p8>
CUTUQUE_APNS_TEAM_ID=<team id da conta Apple Developer>
CUTUQUE_APNS_TOPIC=com.vxfontes.cutuque
# CUTUQUE_APNS_HOST=  # opcional; default por ambiente (ver abaixo)
```

Carregar antes de subir o hub:

```sh
set -a; source config/apns.env; set +a
go run ./cmd/hub
```

O hub sobe **normalmente sem APNs**: se qualquer um de KeyPath/KeyID/TeamID/Topic
faltar, `config.APNSEnabled()` é falso, o Notifier não sobe e a rota
`POST /devices` não é registrada (`log: "apns desabilitado"`). Só o que muda é
que não há push.

## Sandbox vs prod

O host APNs segue o ambiente (`CUTUQUE_ENV`), e `CUTUQUE_APNS_HOST` sobrescreve:

| Ambiente | Host default | Atende tokens de |
|----------|--------------|------------------|
| `dev` (default) | `api.sandbox.push.apple.com` | build de desenvolvimento (Xcode direto no device) |
| `prod` | `api.push.apple.com` | TestFlight / App Store |

Enviar para o host errado devolve `400 BadDeviceToken` — por isso o default
acompanha o ambiente.

## Registro de device (contrato REST)

O app envia o device token ao hub (protegido por bearer):

```
POST /devices
Authorization: Bearer <CUTUQUE_TOKEN>
Content-Type: application/json

{"token":"<hex 32..200 chars>","platform":"ios"}
```

`200 {"ok":true}` no sucesso; `400 {"error":"bad_request"}` se o token não for
hex ou estiver fora da faixa, ou se `platform` vier vazio. Um `410 Unregistered`
da APNs remove o device automaticamente do hub.

## Payload (metadados apenas)

Exemplo `needs_you` (o body é o resumo do pedido, truncado em 140 chars):

```json
{
  "aps": {
    "alert": { "title": "⚠️ minha tarefa", "body": "posso rodar rm -rf /tmp/x?" },
    "sound": "default",
    "thread-id": "sessao-123",
    "category": "NEEDS_YOU",
    "interruption-level": "time-sensitive"
  },
  "session_id": "sessao-123",
  "machine": "macbook",
  "agent": "claude-code",
  "state": "needs_you"
}
```

`done` → `title "✅ <title>"`, `body "concluiu · <machine>"`, `category "DONE"`.
`error` → `title "❌ <title>"`, `body "falhou · <machine>"`, `category "ERROR"`.
Ambos sem `interruption-level`. As três categorias (`NEEDS_YOU`/`DONE`/`ERROR`)
casam com as ações definidas no app (docs/plano Fase 4).

## Testar push no simulador (sem tocar no APNs real)

O simulador do iOS entrega notificações locais via `simctl`, **sem** passar pela
Apple — ideal para validar o layout/categorias sem gastar o APNs real. Com o
simulador aberto e o app instalado:

```sh
cat > /tmp/payload.json <<'JSON'
{
  "Simulator Target Bundle": "com.vxfontes.cutuque",
  "aps": {
    "alert": { "title": "⚠️ minha tarefa", "body": "posso rodar rm -rf /tmp/x?" },
    "sound": "default",
    "thread-id": "sessao-123",
    "category": "NEEDS_YOU",
    "interruption-level": "time-sensitive"
  },
  "session_id": "sessao-123",
  "machine": "macbook",
  "agent": "claude-code",
  "state": "needs_you"
}
JSON

xcrun simctl push booted com.vxfontes.cutuque /tmp/payload.json
```

Troque `category`/`title`/`body`/`state` para exercitar `DONE` e `ERROR`. O
`booted` mira o simulador ativo; `com.vxfontes.cutuque` é o bundle id (= topic).
Nada disso toca o APNs de produção nem consome o device token real.
