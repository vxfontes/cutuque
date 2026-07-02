# 09 — Configurar hooks do Claude Code

Os hooks do Claude Code são um **canal de detecção complementar** ao stream-json:
avisam o hub quando uma sessão pede algo (`Notification`) ou termina (`Stop`),
mesmo quando o hub não está lendo o stream diretamente (ver docs/02 e docs/03).

## Mapeamento

| Hook | Evento normalizado | Efeito no estado |
|------|--------------------|------------------|
| `Notification` | `needs_input` (`Data` = mensagem) | → `needs_you` |
| `Stop` | `finished` | → `done` |

O endpoint é `POST /hooks/claude` e exige token (`Authorization: Bearer <token>`).

## settings.json

No `~/.claude/settings.json` (ou no `.claude/settings.json` do projeto), configure
os hooks para chamar o hub via `curl`. Em dev o token padrão é `dev-token`.

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS -X POST http://127.0.0.1:8787/hooks/claude -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' -d \"{\\\"session_id\\\":\\\"$CLAUDE_SESSION_ID\\\",\\\"hook_event_name\\\":\\\"Notification\\\",\\\"message\\\":\\\"$CLAUDE_NOTIFICATION\\\"}\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "curl -sS -X POST http://127.0.0.1:8787/hooks/claude -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' -d \"{\\\"session_id\\\":\\\"$CLAUDE_SESSION_ID\\\",\\\"hook_event_name\\\":\\\"Stop\\\"}\""
          }
        ]
      }
    ]
  }
}
```

> As variáveis (`$CLAUDE_SESSION_ID`, `$CLAUDE_NOTIFICATION`) são exportadas pelo
> Claude Code para o comando do hook. Ajuste o host/porta e o token conforme o
> ambiente (em prod, use o `CUTUQUE_TOKEN` real e o IP Tailscale do hub).

## Teste rápido

Com o hub rodando (`make run`), simule um hook:

```sh
curl -sS -X POST http://127.0.0.1:8787/hooks/claude \
  -H 'Authorization: Bearer dev-token' \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"<id-de-uma-sessão-conhecida>","hook_event_name":"Stop"}'
```

A sessão correspondente deve transicionar para `done` (visível em `GET /sessions`
e no stream do WebSocket).
