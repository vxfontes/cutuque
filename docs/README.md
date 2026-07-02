# Cutuque — Documentação

Painel de controle remoto, com notificações hápticas, para agentes de terminal
(Claude Code, Codex, OpenCode) que rodam em máquinas pessoais. Operado do iPhone e
Apple Watch, via Tailscale, sem nuvem de terceiros.

> O nome vem de "cutucar": o cutucão no pulso te chamando quando um agente precisa de você.

## Índice

| Doc | Assunto |
|-----|---------|
| [01 — Visão geral](01-visao-geral.md) | Resumo, objetivos, não-objetivos, contexto e restrições |
| [02 — Arquitetura](02-arquitetura.md) | Decisões de arquitetura, componentes do hub, transporte |
| [03 — Modelo de estado](03-modelo-de-estado.md) | Máquina de estados da sessão e detecção |
| [04 — Fluxos e UX](04-fluxos-e-ux.md) | Aprovar de longe, experiência no Watch, haptics |
| [05 — Segurança e erros](05-seguranca-e-erros.md) | Modelo de segurança e tratamento de falhas |
| [06 — Testes](06-testes.md) | Estratégia de testes |
| [07 — Fases de implementação](07-fases-implementacao.md) | Roadmap de construção em fases (v0 → v2) |
| [08 — Decisões e pendências](08-decisoes-e-pendencias.md) | Log de decisões e questões em aberto |
| [09 — Configurar hooks](09-configurar-hooks.md) | Hooks do Claude Code apontando para o hub |
| [10 — Protocolo de controle](10-protocolo-controle-claude.md) | Aprovação nativa via control_request/response (verificado empiricamente) |

## Documento canônico

O design consolidado (snapshot único aprovado no brainstorming) fica em
[`superpowers/specs/2026-07-02-cutuque-design.md`](superpowers/specs/2026-07-02-cutuque-design.md).
Os docs numerados acima expandem esse design por tema e são a referência de trabalho do
dia a dia. Em caso de divergência, alinhar ambos.

## Estado atual

Design aprovado. Próximo passo: plano de implementação detalhado do **v0** (ver
[07 — Fases de implementação](07-fases-implementacao.md)).
