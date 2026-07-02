# 07 — Fases de construção e implementação

Roadmap dividido em fases entregáveis. Cada fase tem **objetivo**, **entregáveis** e
**critérios de aceite**. As fases 0–5 compõem o **v0** (usável no dia a dia); v1 e v2
adicionam alcance e polimento.

O v0 é intencionalmente enxuto: **MacBook + Claude Code**, app iOS mínimo, e a vibração no
Watch via notificação espelhada do iPhone.

> **Estratégia de ambiente:** durante o desenvolvimento, o hub roda **local** (na máquina de
> dev). Subir para o servidor do Hub (`192.0.2.10`) na Tailscale é um passo **único e
> no fim** (Fase 5), não um deploy contínuo. Um passo de cada vez.

---

## Fase 0 — Fundações e infraestrutura

**Objetivo:** ter o esqueleto do projeto e a rede funcionando ponta a ponta (sem lógica de
agente ainda).

**Entregáveis**
- Repositório Go do hub (estrutura de pastas, lint, CI local, `Makefile`/`taskfile`).
- Hub roda **local** (na máquina de dev) e serve um healthcheck REST (`GET /health`).
- Configuração de bind por ambiente (`dev` = localhost; `prod` = interface Tailscale) —
  usada só na Fase 5 para o deploy.
- `.gitignore` cobrindo segredos (APNs `.p8`, chaves ssh).
- Projeto Xcode do app iOS (SwiftUI) que faz um request ao `/health` e mostra "online".

**Critérios de aceite**
- Hub sobe localmente e o app (simulador ou device na mesma rede/Tailscale) lê `/health`.

---

## Fase 1 — Registry + Command API (esqueleto de dados)

**Objetivo:** modelar e servir o estado das sessões, ainda com dados simulados.

**Entregáveis**
- **Session Registry** em memória (máquina + agente + id + estado).
- **Command API**: REST para listar sessões + WebSocket para stream de eventos/output.
- **Token bearer por device** na autenticação da API.
- App iOS: **tela de lista de sessões** consumindo o Registry (com dados fake do hub).

**Critérios de aceite**
- App lista sessões vindas do hub e reage a mudanças de estado via WebSocket.
- Requests sem token válido são recusados.

---

## Fase 2 — Adapter do Claude Code (observar)

**Objetivo:** enxergar sessões reais do Claude Code no MacBook.

**Entregáveis**
- **Adapter Claude Code (observação)**: conexão ao MacBook via `tailscale ssh`.
- Ingestão de `claude -p --output-format stream-json` e/ou hooks
  (`Notification` → `needs_you`; `Stop` → `done`).
- **State Engine** com a máquina de estados de [03](03-modelo-de-estado.md) alimentada por
  eventos nativos.
- App iOS: **tela de detalhe** com output ao vivo.

**Critérios de aceite**
- Uma sessão Claude real aparece no app com estado correto (`running`/`needs_you`/`done`/`error`).
- Output ao vivo aparece no detalhe.

---

## Fase 3 — Adapter do Claude Code (lançar + aprovar)

**Objetivo:** fechar o controle bidirecional (opção b).

**Entregáveis**
- **Lançar sessão** pelo app: escolher máquina + agente + prompt → hub inicia via Adapter.
- **Aprovar/negar** pedidos de permissão pelo app (canal nativo; `tmux send-keys` como
  fallback futuro).
- App iOS: **tela de nova tarefa** + botões Aprovar/Negar no detalhe, sempre exibindo o
  texto do prompt antes.

**Critérios de aceite**
- Disparar uma tarefa do celular sem tocar no terminal.
- Receber um `needs_you`, ver o prompt e aprovar pelo app; a sessão prossegue.

---

## Fase 4 — Notifier APNs + haptic no Watch

**Objetivo:** o cutucão. Aviso em background com vibração no pulso.

**Entregáveis**
- **Notifier (APNs)** no hub com credencial `.p8`; push nas transições
  `→ needs_you`/`→ done`/`→ error` (só metadados, zero código).
- Configuração de push no app iOS (registro de device token no hub).
- Notificação espelhada no **Apple Watch** com vibração.
- Ações de notificação: **Aprovar / Negar / Abrir** direto na notificação (iPhone; Watch
  espelhado).

**Critérios de aceite**
- App fechado: ao concluir uma tarefa, o **Watch vibra** e mostra o aviso.
- Ao pedir permissão, o aviso permite aprovar sem abrir o app.

---

## Fase 5 — Endurecimento do v0

**Objetivo:** confiável o suficiente para uso diário.

**Entregáveis**
- Tratamento de erros de [05](05-seguranca-e-erros.md): alvo offline, perda de push,
  aprovação obsoleta, reconciliação do Registry no restart do hub.
- Suíte de testes de [06](06-testes.md) para hub e fluxos principais do app.
- **Deploy único no Hub:** subir o binário para o servidor `192.0.2.10`, bind na
  interface Tailscale (`prod`), e rodar como serviço persistente (auto-start, restart em
  falha). App passa a apontar para o Hub em vez do local.

**Critérios de aceite**
- E2E do v0 passa: disparar → acompanhar → aprovar → ser avisado.
- Hub sobrevive a reinício sem perder sessões vivas.
- Após o deploy, o app fala com o Hub na Tailscale, de dentro e fora de casa, e nada
  responde fora da Tailscale.

> ✅ **Fim do v0** — Cutuque usável todo dia com MacBook + Claude Code.

---

## v1 — Alcance no Watch e mais agentes

- **App watchOS nativo** com lista de sessões e ações rápidas no pulso.
- **Haptics customizados por tipo** de evento (`done`/`needs_you`/`error`).
- **Fallback tmux** (`capture-pane` + `send-keys`) para cobertura universal.
- **Adapters de Codex** (`codex exec`) e **OpenCode** (`opencode serve`).

## v2 — Reserva de viagem e conveniências

- **Alvo Windows/WSL2** (Tailscale + sshd + tmux no WSL2).
- **Histórico de sessões** (candidato a evoluir para arquitetura event-sourced).
- Melhorias de UX conforme uso real.

---

## Ordem e dependências

```
Fase 0 → Fase 1 → Fase 2 → Fase 3 → Fase 4 → Fase 5  (v0)
                                              │
                                              ▼
                                       v1 → v2
```

Cada fase é independentemente demonstrável e não avança sem seus critérios de aceite.
