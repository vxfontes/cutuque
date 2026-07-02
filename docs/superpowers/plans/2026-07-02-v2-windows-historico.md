# v2 — Windows/WSL2 + histórico — Implementation Plan (ESBOÇO)

> **Status:** esboço iniciado. **Detalhar em passos TDD bite-sized antes de executar.**

**Goal:** Habilitar o desktop Windows como alvo de reserva (para viagens) e adicionar histórico de sessões.

**Architecture:** O desktop Windows entra como "mais um alvo" via Tailscale + sshd + tmux dentro do WSL2 — reusando os adapters existentes. O histórico evolui o Registry (hoje em memória) para persistência, candidato à arquitetura event-sourced descrita no design.

**Tech Stack:** Go (persistência no **Postgres já existente no servidor** — schema/base dedicada `cutuque`, via `pgx` ou `database/sql`), WSL2, Tailscale.

## Global Constraints

Herda v0/v1. Nenhuma mudança de segurança: continua Tailscale-only. **Reusar o Postgres já
configurado no servidor local** (banco onde a usuária mantém suas bases) — criar uma
base/schema dedicada `cutuque`, sem provisionar um novo servidor de banco. Credenciais do
Postgres via env (`CUTUQUE_DATABASE_URL`), nunca versionadas.

## Sub-planos (a expandir em planos próprios)

- [ ] **v2.1 — Alvo Windows/WSL2** — runbook de setup (Tailscale + sshd + tmux no WSL2); validar que os adapters existentes funcionam sem mudança. Teste E2E com o desktop.
- [ ] **v2.2 — Persistência do Registry no Postgres** — criar base/schema `cutuque` no Postgres existente; migrations; mover o Registry de memória para o banco; reconciliação na subida. Testes com Postgres de teste.
- [ ] **v2.3 — Histórico de sessões (event log)** — registrar transições e output relevante; base para replay. Testes.
- [ ] **v2.4 — App: tela de histórico** — navegar sessões passadas e seus eventos.
- [ ] **v2.5 — Conveniências de UX** — ajustes conforme uso real (filtros, favoritos de máquina/agente, etc.).

## Critérios de aceite

- Deixar o desktop Windows ligado e controlá-lo pelo app durante uma viagem, com os mesmos avisos hápticos.
- Consultar o histórico de uma sessão concluída.

## Fim do roadmap planejado

Melhorias futuras a partir daqui saem do uso real.
