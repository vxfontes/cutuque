# Fase 1 — Registry + Command API — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar** —
> use a skill writing-plans para expandir cada task com testes e código completos, seguindo
> o padrão da Fase 0.

**Goal:** Modelar e servir o estado das sessões (com dados simulados), com autenticação por token, e o app iOS listando sessões em tempo real.

**Architecture:** Session Registry em memória no hub; Command API REST (listar) + WebSocket (stream de eventos/estado); middleware de token bearer por device. App iOS ganha a tela de lista consumindo o Registry.

**Tech Stack:** Go (stdlib + `gorilla/websocket` ou `nhooyr.io/websocket` — decidir na expansão), SwiftUI.

## Global Constraints

Herda as da Fase 0. Adicional: primeira dependência externa permitida (biblioteca de WebSocket) — justificar e fixar versão.

## Tasks (a expandir)

- [ ] **Task 1 — Modelo `Session`** — struct com `ID`, `Machine`, `Agent`, `State` (enum das definidas no doc 03), timestamps. Testes de serialização JSON.
- [ ] **Task 2 — Session Registry em memória** — CRUD thread-safe (`Add`, `Get`, `List`, `UpdateState`), com mutex. Testes de concorrência.
- [ ] **Task 3 — Middleware de token bearer** — valida `Authorization: Bearer <token>` contra `config.Token`; rejeita 401 sem token. Testes de aceitar/recusar.
- [ ] **Task 4 — REST `GET /sessions`** — lista sessões do Registry em JSON, protegida pelo middleware. Testes de contrato.
- [ ] **Task 5 — WebSocket `/ws`** — stream de eventos de mudança de estado; broadcast a clientes conectados. Testes com cliente fake.
- [ ] **Task 6 — Seed de dados fake** — endpoint/dev-only para popular sessões simuladas e disparar transições, para exercitar o app.
- [ ] **Task 7 — App iOS: tela de lista** — consome `GET /sessions` + assina `/ws`; mostra sessões com cor por estado; atualiza em tempo real. Verificação manual.

## Critérios de aceite

- App lista sessões vindas do hub e reage a mudanças via WebSocket.
- Requests sem token válido são recusados (401).

## Próximo passo

[`2026-07-02-fase-2-adapter-claude-observar.md`](2026-07-02-fase-2-adapter-claude-observar.md)
