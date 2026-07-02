# 06 — Estratégia de testes

## Por componente

- **Adapters** — testados contra saídas gravadas de cada agente (fixtures de
  `stream-json` do Claude Code, respostas HTTP do OpenCode, JSON do `codex exec`).
  Garante que eventos normalizados sejam emitidos corretamente sem depender do agente real.
- **State Engine** — testes de tabela cobrindo **todas** as transições da máquina de
  estados, incluindo os casos ambíguos do fallback tmux e a regra de desempate
  (`→ needs_you` na dúvida).
- **Command API** — testes de contrato (WebSocket/REST) com um app cliente fake:
  `launch`, `send_text`, `approve`, `deny`, e assinatura de stream.
- **Notifier** — mock do APNs; verificar o mapeamento estado → tipo de haptic + metadado, e
  que **nenhum código-fonte** vaza no payload.
- **App iOS/watchOS** — testes de UI dos fluxos principais (lista, ver output, aprovar,
  disparar).

## End-to-end

Cenário mínimo do v0 (MacBook + Claude Code):

1. Disparar tarefa pelo app.
2. Observar o output ao vivo.
3. Receber `needs_you` num pedido de permissão e aprovar pelo app.
4. Receber o aviso (push + haptic) na conclusão.

## Casos de borda a cobrir

- Alvo offline no momento do disparo.
- Perda de push (verificar que o app mostra o estado correto ao abrir).
- Aprovação enviada depois que a sessão já mudou de estado (deve ser rejeitada).
- Detecção tmux ambígua (deve cair em `needs_you`).
- Reinício do hub com sessões vivas (reconciliação do Registry).
- Duas sessões simultâneas na mesma máquina (não confundir estados/identificadores).
