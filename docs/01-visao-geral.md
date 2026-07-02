# 01 — Visão geral

## Resumo

Cutuque é um painel de controle remoto, com notificações hápticas, para agentes de
terminal (Claude Code, Codex, OpenCode) que rodam em máquinas pessoais distribuídas.
O usuário opera tudo pelo iPhone e Apple Watch: dispara tarefas, acompanha o output ao
vivo, aprova pedidos de permissão e é avisado por vibração no pulso quando algo conclui
ou precisa de atenção — de qualquer lugar, via Tailscale, sem depender de nuvem de
terceiros.

## Objetivos

- **Loop completo:** disparar → acompanhar → aprovar → ser avisado, tudo do celular/Watch.
- **Multi-agente:** Claude Code, Codex, OpenCode e, no fallback, qualquer comando de terminal.
- **Aviso confiável em background:** vibração no Apple Watch mesmo com o app fechado.
- **Privacidade:** código-fonte nunca sai da rede privada (Tailscale); a nuvem da Apple
  (APNs) recebe apenas metadados ("sessão X concluiu").
- **Encaixar no fluxo atual:** aproveitar Tailscale, tmux e as máquinas já existentes.

## Não-objetivos (por enquanto)

- Substituir a experiência de terminal no desktop — Cutuque complementa, não substitui.
- Suporte a agentes sem interface programável nem terminal.
- Multiusuário / colaboração — é uma ferramenta pessoal single-user.
- Histórico/replay de longo prazo de sessões (candidato a v2+).

## Contexto e restrições

- **Rede:** todas as máquinas e o celular estão numa mesma Tailscale.
- **Hub:** servidor local em `192.0.2.10` (Tailscale), sempre ligado, com internet de saída
  (necessária para falar com o APNs da Apple).
- **Máquinas-alvo:**
  - **MacBook** (uso principal) — tmux nativo.
  - **Desktop Windows** (reserva para viagens) — os agentes rodam em tmux **dentro do WSL2**;
    Tailscale + sshd no WSL2 fazem dele "só mais um alvo" idêntico ao Mac.
- **Cliente:** app nativo iOS + watchOS (SwiftUI). Licença Apple disponível para publicação.
- **Linguagem do hub:** Go (binário único, forte em concorrência e SSH).

## Personas / uso típico

- **Em casa, longe do Mac:** dispara uma refatoração pelo celular, larga o telefone, e é
  cutucado no pulso quando o agente pede permissão ou conclui.
- **Viajando:** deixa o desktop Windows ligado; controla e acompanha tudo pela Tailscale do
  celular, com os mesmos avisos hápticos.
