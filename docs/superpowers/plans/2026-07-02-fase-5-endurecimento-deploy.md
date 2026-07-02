# Fase 5 — Endurecimento + Deploy no Hub — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar.**
> Esta é a fase que **fecha o v0**: torna confiável e faz o **deploy único** no Hub.

**Goal:** Deixar o v0 confiável para uso diário e subir o hub para o servidor `192.0.2.10` na Tailscale.

**Architecture:** Implementa o tratamento de erros do doc 05, completa a suíte de testes do doc 06, e empacota o hub como serviço persistente rodando com bind na interface Tailscale (`prod`). O app passa a apontar para o Hub.

**Tech Stack:** Go, launchd/systemd, SwiftUI.

## Global Constraints

Herda anteriores. Este é o **único** momento em que se mexe no servidor do Hub (decisão #13). Em `prod`, o hub escuta **apenas** na interface Tailscale.

## Tasks (a expandir)

- [ ] **Task 1 — Alvo offline** — Registry marca sessões como indisponíveis quando o alvo cai; app mostra estado degradado sem travar. Testes.
- [ ] **Task 2 — Push perdido = estado consistente** — garantir que, ao abrir, o app vê o estado real do Registry mesmo sem o push. Testes.
- [ ] **Task 3 — Ação obsoleta rejeitada** — reforço/teste do invariante da Fase 3 (aprovar em sessão que já mudou de estado). Testes.
- [ ] **Task 4 — Reconciliação no restart** — ao subir, o hub reconstrói o Registry a partir das sessões vivas nos alvos. Testes.
- [ ] **Task 5 — Cobertura de testes do doc 06** — fechar lacunas (adapters, state engine, command API, notifier). 
- [ ] **Task 6 — Empacotar e configurar bind `prod`** — build do binário; conferir bind na interface Tailscale (`CUTUQUE_ENV=prod`). 
- [ ] **Task 7 — Serviço persistente no servidor** — instalar como serviço (auto-start, restart em falha) no `192.0.2.10`; colocar a credencial APNs `.p8` no servidor com permissões restritas.
- [ ] **Task 8 — Repontar o app para o Hub** — configurar a `baseURL` do app para o IP Tailscale do Hub; revisar as exceções de ATS (preferir HTTPS/exceção específica em vez de arbitrary loads).
- [ ] **Task 9 — E2E final do v0** — disparar → acompanhar → aprovar → ser avisado, contra o Hub, de dentro e fora de casa.

## Critérios de aceite

- E2E do v0 passa contra o Hub.
- Hub sobrevive a reinício sem perder sessões vivas.
- Após o deploy, o app fala com o Hub na Tailscale (dentro e fora de casa) e nada responde fora da Tailscale.

> ✅ **Fim do v0.**

## Próximo passo

[`2026-07-02-v1-watchos-tmux-multiagente.md`](2026-07-02-v1-watchos-tmux-multiagente.md)
