# 03 — Modelo de estado

## Máquina de estados da sessão

Cada sessão de agente vive em exatamente um estado por vez.

| Estado | Significado | Ação no app | Dispara push? |
|--------|-------------|-------------|:---:|
| `running` | agente trabalhando | acompanhar output | não |
| `needs_you` | pediu permissão / fez pergunta / travou esperando input | responder/aprovar | **sim** |
| `done` | tarefa concluída | revisar resultado | **sim** |
| `error` | crashou / erro | investigar | **sim** |
| `idle` | sessão viva, sem tarefa ativa | disparar novo prompt | não |

## Transições

```
        launch/prompt
 idle ───────────────▶ running
   ▲                    │  │  │
   │           needs_input  │  finished
   │                    │   │  │
   │                    ▼   │  ▼
   │              needs_you │ done ──(novo prompt)──▶ running
   │                    │   │  │
   │  (usuário responde)│   │  └──(novo prompt)──▶ running
   │                    ▼   ▼
   └──────────────────── error ──(retry)──▶ running
```

- `running → needs_you` — agente pediu permissão ou input, ou travou aguardando.
- `needs_you → running` — usuário respondeu/aprovou.
- `running → done` — tarefa concluída.
- `running → error` — falha/crash.
- `done|error|idle → running` — novo disparo.

As transições para **`needs_you`, `done` e `error` disparam notificação + haptic**.

## Detecção do estado

A qualidade do sinal depende do canal:

- **Nativo (preferido):** evento exato do próprio agente.
  - Claude Code: hooks (`Notification` → `needs_you`; `Stop` → `done`) e eventos do
    `stream-json` (uso de ferramenta, texto, pedido de permissão).
  - OpenCode: estado via API HTTP.
  - Codex: código de saída + JSON do `codex exec`.
- **tmux (fallback):** heurística sobre o buffer capturado (`tmux capture-pane`).
  Ex.: presença de um prompt de confirmação → `needs_you`; padrão de conclusão → `done`.

### Regra de desempate

Quando o fallback tmux estiver ambíguo, **preferir `needs_you`** (chamar o usuário) a
assumir `done` erroneamente. É melhor cutucar à toa do que deixar o usuário esperando por
um aviso que nunca vem.
