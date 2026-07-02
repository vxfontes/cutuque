# 04 — Fluxos e UX

## Fluxo: disparar uma tarefa (do celular)

1. No app, usuário escolhe a máquina-alvo e o agente, e digita o prompt.
2. Command API recebe `launch` → Adapter nativo inicia a sessão na máquina via `tailscale ssh`.
3. State Engine registra a sessão como `running`; app passa a receber o stream de output.

## Fluxo: aprovar de longe

1. Agente emite um pedido de permissão (ex.: "permitir editar arquivo X?").
2. Adapter detecta (via hook nativo quando possível) e captura o **contexto** (texto do prompt).
3. State Engine move a sessão para `needs_you` e o Notifier dispara push.
4. Watch vibra (padrão insistente) e mostra ações rápidas: **Aprovar / Negar / Abrir no iPhone**.
5. Usuário decide → app envia a ação ao hub → hub responde ao agente pelo canal nativo
   (ou, no fallback, injeta a tecla via `tmux send-keys`).

> **Invariante de segurança:** o app SEMPRE mostra o texto do prompt antes da decisão.
> Nunca se aprova às cegas.

## Fluxo: ser avisado de conclusão

1. Agente termina → Adapter emite `finished` → State Engine move para `done`.
2. Notifier dispara push com haptic suave.
3. Watch vibra "✅ concluiu"; ao abrir, usuário revisa o resultado.

## Experiência no Watch + haptics

O Watch mostra **estado e decisão rápida**, não código.

| Evento | Haptic | Texto | Ações rápidas |
|--------|--------|-------|---------------|
| `done` | suave, duplo | ✅ [sessão] concluiu | Abrir |
| `needs_you` | insistente/forte | ⚠️ [sessão] precisa de você | Aprovar / Negar / Abrir no iPhone |
| `error` | staccato distinto | ❌ [sessão] falhou | Abrir |

- **App watchOS:** lista de sessões com bolinha de cor por estado; tocar em `needs_you`
  mostra a pergunta + botões.
- **Implementação:** `WKInterfaceDevice.play(_:)` no app para haptics + categorias de
  notificação do APNs para as ações no pulso.

> Nota: no **v0**, a notificação no Watch é a espelhada da notificação do iPhone (ainda sem
> app watchOS nativo). Haptics customizados por tipo e ações rápidas no pulso entram no v1.
> Ver [07 — Fases de implementação](07-fases-implementacao.md).

## App iOS — telas principais (v0)

- **Lista de sessões** — todas as sessões com estado (cor/ícone) e máquina de origem.
- **Detalhe da sessão** — output ao vivo; quando `needs_you`, mostra o prompt + Aprovar/Negar.
- **Nova tarefa** — escolher máquina + agente + prompt e disparar.
