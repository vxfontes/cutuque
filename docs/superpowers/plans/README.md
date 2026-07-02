# Cutuque — Planos de implementação

Cada fase é um plano independentemente entregável e testável. A **Fase 0 está detalhada**
em passos TDD; as demais são **esboços iniciados** — expandir em passos bite-sized (usando a
skill writing-plans) antes de executar cada uma.

## Ordem

| Plano | Versão | Status |
|-------|:------:|--------|
| [Fase 0 — Fundações](2026-07-02-fase-0-fundacoes.md) | v0 | ✅ **Concluída** (2026-07-02) |
| [Fase 1 — Registry + Command API](2026-07-02-fase-1-registry-command-api.md) | v0 | ✅ **Concluída** (2026-07-02, review ludmilla aplicada) |
| [Fase 2 — Adapter Claude (observar)](2026-07-02-fase-2-adapter-claude-observar.md) | v0 | ✅ **Concluída** (2026-07-02; runner ainda não exposto no cmd/hub — entra na Fase 3 junto do launch) |
| [Fase 3 — Adapter Claude (lançar + aprovar)](2026-07-02-fase-3-adapter-claude-lancar-aprovar.md) | v0 | ✅ **Concluída** (2026-07-02; aprovação nativa via protocolo de controle — ver doc 10; E2E real verificado) |
| [Fase 4 — Notifier APNs + haptic](2026-07-02-fase-4-notifier-apns-haptic.md) | v0 | Esboço |
| [Fase 5 — Endurecimento + Deploy no Hub](2026-07-02-fase-5-endurecimento-deploy.md) | v0 | Esboço (fecha o v0) |
| [v1 — watchOS + tmux + Codex/OpenCode](2026-07-02-v1-watchos-tmux-multiagente.md) | v1 | Esboço |
| [v2 — Windows/WSL2 + histórico](2026-07-02-v2-windows-historico.md) | v2 | Esboço |

## Convenções

- **Módulo Go:** `github.com/vxfontes/cutuque/hub`
- **Banco:** v0/v1 em memória; persistência só no v2, no **Postgres já existente** (base `cutuque`).
- **Ambiente:** dev = local (`127.0.0.1`); prod = interface Tailscale (`192.0.2.10`), só na Fase 5.
- Design de referência: [`../../README.md`](../../README.md).
