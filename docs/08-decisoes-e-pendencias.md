# 08 — Decisões e pendências

## Decisões travadas

| # | Decisão | Racional |
|---|---------|----------|
| 1 | **Nome: Cutuque** | O cutucão no pulso te chamando; casa com o haptic. |
| 2 | **Escopo: loop completo** (disparar, acompanhar, aprovar, avisar) | É o que faria usar todo dia. |
| 3 | **Multi-agente e agnóstico** (Claude, Codex, OpenCode; tmux p/ o resto) | Não amarrar a um só agente. |
| 4 | **Hub cérebro + apps finos** | Simplifica o watchOS e acelera publicar o app. |
| 5 | **Controle native-first (Cano 2)**, tmux como fallback | Sinal preciso; tmux garante universalidade + attach. |
| 6 | **Hub pode lançar sessões** (opção b) | Disparar do celular sem abrir terminal. |
| 7 | **Conectividade: Tailscale, sem nuvem** | Já existe; privacidade do código. |
| 8 | **Hub em `192.0.2.10`; alvos via `tailscale ssh`** | Servidor sempre ligado; alvos distribuídos. |
| 9 | **Linguagem do hub: Go** | Binário único, forte em concorrência/SSH. |
| 10 | **Cliente: app nativo iOS + watchOS (SwiftUI)** | Único caminho para haptics de verdade; publicável. |
| 11 | **Windows como alvo via WSL2** | tmux + Tailscale + sshd no WSL2 = alvo idêntico ao Mac. |
| 12 | **Transporte: WebSocket/REST (ao vivo) + APNs (background)** | Cada um no que é bom. |
| 13 | **Desenvolver local; deploy no Hub só no fim (Fase 5)** | Um passo de cada vez; evitar deploy contínuo no servidor durante o dev. |
| 14 | **App watchOS nativo fica no v1** (depois do deploy no Hub) | No v0, a notificação espelhada do iPhone já vibra o Watch; app nativo é polimento. |
| 15 | **Sem mTLS no v0** | Tailscale já faz auth mútua na rede + token bearer no app; mTLS seria 3ª camada redundante. Reavaliar em v1 se expor algo fora da Tailscale. |

## Pendências (a decidir)

Nenhuma pendência aberta. Design pronto para o plano de implementação da Fase 0.

## Alternativas consideradas e descartadas

- **Hub "burro" + app esperto** — reimplementaria a lógica em Swift e sobrecarregaria o
  watchOS. Descartado em favor de hub cérebro.
- **Hub event-sourced desde o início** — over-engineering para o MVP; a arquitetura atual
  pode evoluir para isso no v2 (histórico).
- **Push via app de terceiros (ntfy/Pushcut/Telegram)** — haptics pobres no Watch e
  interação limitada; descartado dado o requisito de vibração caprichada.
- **Relay na nuvem (VPS)** — desnecessário: o próprio hub fala com o APNs; Tailscale já dá
  alcance de qualquer lugar.
- **Claude Code hospedado (web/mobile da Anthropic)** — roda na nuvem da Anthropic, não nas
  máquinas locais do usuário; não atende o requisito de controlar MacBook/Windows próprios.
