# Fase 4 — Notifier APNs + haptic no Watch — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar.**

**Goal:** O cutucão — aviso em background com vibração no Apple Watch (espelhada do iPhone) e ações direto na notificação.

**Architecture:** Notifier no hub envia push via APNs nas transições `→ needs_you`/`→ done`/`→ error`, com apenas metadados (zero código). O app iOS registra o device token no hub e define categorias de notificação com ações. O Watch recebe a notificação espelhada e vibra.

**Tech Stack:** Go (cliente APNs HTTP/2 com JWT do `.p8`), SwiftUI + UserNotifications.

## Global Constraints

Herda anteriores. Credencial APNs `.p8` **só no hub** (nunca no app, nunca versionada). Payload do push **não** contém código-fonte — só `{sessionId, machine, agent, state}`.

> **Credenciais já provisionadas (2026-07-02):** a key mora em `config/key.p8` e as env vars
> (`CUTUQUE_APNS_KEY_PATH`, `CUTUQUE_APNS_KEY_ID`, `CUTUQUE_APNS_TEAM_ID`, `CUTUQUE_APNS_TOPIC`)
> em `config/apns.env` — diretório `/config/` inteiro no `.gitignore`. Valores também na nota
> "credenciais" do Maestri. Carregar com `set -a; source config/apns.env; set +a` antes de subir o hub.

## Tasks (a expandir)

- [ ] **Task 1 — Cliente APNs no hub** — conexão HTTP/2 + JWT (ES256) a partir do `.p8`; enviar push a um device token. Testes com mock do endpoint APNs.
- [ ] **Task 2 — Registro de device token** — REST `POST /devices` guarda o token do device (protegido por bearer). Testes.
- [ ] **Task 3 — Notifier ligado ao State Engine** — nas transições relevantes, montar payload (metadados + categoria/haptic por tipo) e enviar. Testes de mapeamento estado → payload; garantir ausência de código no payload.
- [ ] **Task 4 — App iOS: permissão + registro de push** — pedir autorização de notificações, obter device token, enviar ao hub. Verificação manual.
- [ ] **Task 5 — App iOS: categorias e ações** — definir categorias `needs_you` (Aprovar/Negar/Abrir), `done` (Abrir), `error` (Abrir); tratar ações. Verificação manual.
- [ ] **Task 6 — Verificação no Watch** — com app fechado, concluir tarefa → Watch vibra e mostra aviso; num `needs_you`, aprovar pela notificação sem abrir o app.

## Critérios de aceite

- App fechado: ao concluir, o Watch vibra e mostra o aviso.
- Ao pedir permissão, o aviso permite aprovar sem abrir o app.

## Próximo passo

[`2026-07-02-fase-5-endurecimento-deploy.md`](2026-07-02-fase-5-endurecimento-deploy.md)
