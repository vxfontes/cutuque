# Fase 3 — Adapter do Claude Code (lançar + aprovar) — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar.**

**Goal:** Fechar o controle bidirecional — lançar tarefas do celular e aprovar/negar pedidos de permissão.

**Architecture:** Command API ganha comandos `launch`, `approve`, `deny`, `send_text`; o Adapter os executa pelo canal nativo do Claude Code (e, no futuro, `tmux send-keys` como fallback). O app iOS ganha a tela de nova tarefa e os botões de decisão, sempre exibindo o texto do prompt antes.

**Tech Stack:** Go, SwiftUI.

## Global Constraints

Herda anteriores. **Invariante de segurança:** nunca aprovar sem exibir o texto do prompt; o hub valida o estado atual da sessão antes de aplicar uma ação (rejeitar ação obsoleta).

## Tasks (a expandir)

- [ ] **Task 1 — Comando `launch`** — REST `POST /sessions` com `{machine, agent, prompt}`; Adapter inicia a sessão via canal nativo; retorna a `Session` criada. Testes.
- [ ] **Task 2 — Captura de contexto do permission prompt** — Adapter guarda o texto do pedido em `Session` quando entra em `needs_you`. Testes com fixtures.
- [ ] **Task 3 — Comandos `approve`/`deny`** — REST `POST /sessions/{id}/approve|deny`; valida estado atual == `needs_you`; responde ao agente pelo canal nativo. Testes de aceitar/rejeitar-obsoleto.
- [ ] **Task 4 — Comando `send_text`** — enviar input textual arbitrário à sessão. Testes.
- [ ] **Task 5 — App iOS: tela de nova tarefa** — escolher máquina + agente + prompt e disparar. Verificação manual.
- [ ] **Task 6 — App iOS: aprovar/negar no detalhe** — exibir prompt + botões; enviar ação; refletir mudança de estado. Verificação manual.

## Critérios de aceite

- Disparar uma tarefa do celular sem tocar no terminal.
- Receber um `needs_you`, ver o prompt e aprovar pelo app; a sessão prossegue.

## Próximo passo

[`2026-07-02-fase-4-notifier-apns-haptic.md`](2026-07-02-fase-4-notifier-apns-haptic.md)
