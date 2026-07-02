# 05 — Segurança e tratamento de erros

## Segurança

- Hub escuta **apenas na interface Tailscale** — nunca exposto à internet pública.
- **Token bearer por device** no WebSocket/REST, além da identidade da Tailscale.
- Credencial **APNs (.p8)** só no hub, nunca embarcada no app.
- Output de código trafega **só na Tailscale** (alvo → hub → app). No APNs vai apenas
  metadado ("sessão X concluiu"), zero código.
- Segredos do hub (token do APNs, chaves ssh) ficam fora do controle de versão
  (`.gitignore`) e com permissões restritas no servidor.

### A decidir

- **mTLS** além do token bearer — avaliar custo/benefício, dado que já é Tailscale-only.
  Recomendação: não no v0; reavaliar em v1. Ver [08 — Decisões e pendências](08-decisoes-e-pendencias.md).

## Tratamento de erros

- **Alvo inacessível** (máquina offline / fora da Tailscale) — sessões marcadas como
  indisponíveis no Registry; app mostra estado degradado, não trava.
- **Falha ao entregar push** — o estado real permanece no hub; ao abrir o app, o usuário vê
  o estado correto mesmo que o push tenha se perdido. **O push é conveniência, não a
  verdade** — a verdade é o Registry.
- **Detecção tmux ambígua** — na dúvida, preferir `needs_you` (chamar o usuário) a assumir
  `done` erroneamente.
- **Ação de aprovação em sessão que já mudou de estado** — hub valida o estado atual antes
  de aplicar; ação obsoleta é rejeitada com feedback claro no app.
- **Queda de conexão hub ↔ alvo** — Adapter tenta reconectar; sessões afetadas ficam
  `indisponíveis` até religar, sem perder o histórico de estado conhecido.
- **Reinício do hub** — Registry deve ser reconstruível a partir das sessões vivas nos
  alvos (reconciliação na subida), para não "esquecer" sessões em andamento.
