# v1 — watchOS nativo + tmux + Codex/OpenCode — Implementation Plan (ESBOÇO)

> **Status:** ✅ implementado (v1.1–v1.6). Watch nativo + haptics, fallback tmux,
> adapters Codex e OpenCode e seleção de agente por sessão estão no Hub/app.
> OpenCode ganhou paridade de descoberta/adoção com o Codex (discover + transcript).

**Goal:** Alcance de verdade no pulso (app watchOS nativo com haptics customizados e ações rápidas), cobertura universal (fallback tmux) e mais agentes (Codex, OpenCode).

**Architecture:** Adiciona um target watchOS ao app; o hub ganha o tmux Collector (fallback) e novos adapters (Codex via `codex exec`, OpenCode via `opencode serve`), reusando o State Engine e o contrato de eventos normalizados da Fase 2.

**Tech Stack:** SwiftUI + WatchKit (`WKInterfaceDevice.play`), Go.

## Global Constraints

Herda o v0. Os novos adapters devem emitir os **mesmos** eventos normalizados do doc 02 — sem lógica de estado duplicada por agente.

## Sub-planos (a expandir em planos próprios)

- [x] **v1.1 — App watchOS nativo** — target watchOS; lista de sessões com bolinha de estado; tela de `needs_you` com Aprovar/Negar no pulso; sincronização com o iPhone.
- [x] **v1.2 — Haptics customizados por tipo** — padrões distintos para `done` (suave duplo), `needs_you` (insistente), `error` (staccato) via `WKInterfaceDevice.play`.
- [x] **v1.3 — tmux Collector (fallback)** — `capture-pane` para ler + `send-keys` para escrever; detecção por heurística de texto com a regra de desempate `→ needs_you`. Testes com buffers gravados.
- [x] **v1.4 — Adapter Codex** — `codex exec` + parsing do JSON; disparos one-shot mapeados para eventos. Testes com fixtures. Inclui descoberta/adoção e recap (rollouts de `~/.codex/sessions`).
- [x] **v1.5 — Adapter OpenCode** — implementado via `opencode run --format json` (one-shot streaming, como o Codex), **não** via `opencode serve`/HTTP. Descoberta/adoção e recap lendo o storage local (`~/.local/share/opencode/storage`), em paridade com o Codex.
- [x] **v1.6 — Seleção de agente por sessão** — app permite escolher Claude/Codex/OpenCode ao lançar.

## Critérios de aceite

- App watchOS nativo lista sessões e aprova no pulso, com haptics distintos por tipo.
- Um comando de terminal qualquer (sem adapter nativo) é observável via fallback tmux.
- Codex e OpenCode aparecem e são controláveis no mesmo painel.

## Próximo passo

[`2026-07-02-v2-windows-historico.md`](2026-07-02-v2-windows-historico.md)
