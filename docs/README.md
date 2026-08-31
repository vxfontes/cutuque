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
| [11 — APNs](11-apns.md) | Credenciais, payloads e o que **nunca** vai no push |
| [12 — Deploy no ZimaOS](12-deploy-zimaos.md) | O hub como container no macmini |
| [13 — Alvo Windows/WSL2](13-alvo-windows-wsl2.md) | Máquina Windows como alvo idêntico ao Mac |
| [Submissão à App Store](app-store-submission.md) | Checklist de publicação + **histórico de versões** |
| [Protocolo do board](board-protocol.md) | Colunas, regras e CLI do Kanban dos agentes |

## Documento canônico

O design consolidado (snapshot único aprovado no brainstorming) fica em
[`superpowers/specs/2026-07-02-cutuque-design.md`](superpowers/specs/2026-07-02-cutuque-design.md).
Os docs numerados acima expandem esse design por tema e são a referência de trabalho do
dia a dia. Em caso de divergência, alinhar ambos.

## Estado atual

**[31/08/2026]** v0 e v1 no ar; board e deck construídos; v2 parcial (Postgres). App na versão
**2.9.0 (26)**. O parágrafo original desta seção ("design aprovado, próximo passo é o plano do v0")
ficou verdadeiro por poucos dias em julho de 2026 e passou meses desatualizado aqui — fica o registro
de que **este índice é doc de entrada, não diário**: para o que está pronto e o que falta, a fonte é
o board (`cutuque task list`) e, no vault, `Geral — Estado Atual e Pendências`.

Os docs numerados são **de design** e guardam a intenção original de cada tema, com notas inline
datadas onde a realidade divergiu. Onde o número mudou (versão, tetos, contagem de testes), a fonte
é o código; o doc explica o **porquê**.
