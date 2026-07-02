# Fase 2 — Adapter do Claude Code (observar) — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar.**

**Goal:** Enxergar sessões reais do Claude Code no MacBook, com estado correto e output ao vivo no app.

**Architecture:** Adapter do Claude Code conecta ao MacBook via `tailscale ssh`, ingere `claude -p --output-format stream-json` e/ou hooks (`Notification` → `needs_you`, `Stop` → `done`), normaliza em eventos e alimenta o State Engine, que atualiza o Registry (Fase 1).

**Tech Stack:** Go (exec/ssh, parsing de JSON stream), SwiftUI.

## Global Constraints

Herda anteriores. Adicional: o adapter deve emitir **eventos normalizados** independentes do agente (contrato do doc 02), para que Codex/OpenCode (v1) reusem o State Engine.

## Tasks (a expandir)

- [ ] **Task 1 — Contrato de evento normalizado** — `type Event` com tipos `SessionStarted`, `OutputChunk`, `NeedsInput`, `PermissionRequested`, `Finished`, `Errored`. Testes.
- [ ] **Task 2 — State Engine** — aplica eventos → transições da máquina de estados (doc 03), incluindo regra de desempate (`→ needs_you` na dúvida). Testes de tabela cobrindo todas as transições.
- [ ] **Task 3 — Parser do `stream-json` do Claude Code** — a partir de fixtures gravadas, converter linhas em `Event`. Testes com fixtures.
- [ ] **Task 4 — Ingestão de hooks do Claude Code** — receber `Notification`/`Stop` (via endpoint local do hub ou arquivo) e mapear para eventos. Testes.
- [ ] **Task 5 — Transporte `tailscale ssh`** — abrir/observar sessão no MacBook; reconexão em queda. Testes com um "alvo" fake (comando local que emite fixtures).
- [ ] **Task 6 — Ligar Adapter → State Engine → Registry → WebSocket** — fluxo completo de observação. Teste de integração.
- [ ] **Task 7 — App iOS: tela de detalhe** — output ao vivo da sessão via WebSocket. Verificação manual com sessão Claude real.

## Critérios de aceite

- Uma sessão Claude real aparece no app com estado correto (`running`/`needs_you`/`done`/`error`).
- Output ao vivo aparece no detalhe.

## Próximo passo

[`2026-07-02-fase-3-adapter-claude-lancar-aprovar.md`](2026-07-02-fase-3-adapter-claude-lancar-aprovar.md)
