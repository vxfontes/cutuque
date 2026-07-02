# 02 — Arquitetura

## Visão de alto nível

```
[iPhone / Apple Watch]  <—WebSocket/REST (Tailscale)—>  [Hub @ 192.0.2.10]
        ^                                                        |
        |                                          tailscale ssh | (native-first, tmux fallback)
        └────────— APNs (só metadados) —————┐                    v
                                            |         [MacBook]  [Windows/WSL2]  ...
                                     [Apple APNs]      Claude / Codex / OpenCode
```

## Decisões de arquitetura

### Hub cérebro + apps finos

Toda a inteligência (registro de sessões, detecção de estado, orquestração, APNs) mora no
hub. Os apps iOS/watchOS são viewers finos: mostram estado e enviam ações. Isso é crucial
para o watchOS (recursos limitados) e para publicar um app simples rapidamente.

### Controle native-first (Cano 2), tmux como fallback

O canal primário de controle é a **interface nativa** de cada agente, que dá eventos
precisos e estruturados em vez de "ler a tela":

| Agente | Interface nativa | Uso |
|--------|------------------|-----|
| Claude Code | headless/SDK (`claude -p --output-format stream-json`) + hooks (Stop, Notification, PreToolUse) | lançar, observar, detectar `done`/`needs_you`, aprovar |
| OpenCode | servidor HTTP embutido (`opencode serve`) + SDK | lançar, observar via API |
| Codex | `codex exec` + saída JSON | disparos one-shot |

O **tmux** permanece como:
- **fallback universal** — para qualquer agente/comando sem interface nativa boa;
- **escape hatch** — o usuário ainda pode `ssh` + attachar a sessão real quando quiser.

### O hub pode lançar sessões

Além de observar, o hub **inicia tarefas novas** nas máquinas-alvo pelas interfaces
nativas. O usuário dispara do celular sem abrir terminal.

### Transporte

- **WebSocket + REST** (hub ↔ app) sobre Tailscale: lista de sessões, stream de output ao
  vivo, envio de texto/ações, aprovação de prompts. Usado quando o app está aberto.
- **APNs** (hub → Apple → Watch/iPhone): notificações e haptics quando o app está em
  background/fechado.

## Componentes do hub

Cada componente tem uma responsabilidade única e um contrato claro. Isso mantém as partes
testáveis e substituíveis de forma isolada.

- **Session Registry** — fonte da verdade das sessões conhecidas: máquina + agente +
  identificador + estado atual. Os demais componentes leem/atualizam aqui.
- **Adapters nativos** (um por tipo de agente) — encapsulam como lançar/observar cada
  agente: Claude Code (headless/SDK + hooks), OpenCode (HTTP), Codex (exec). Rodam contra
  as máquinas-alvo via `tailscale ssh`. Emitem eventos normalizados para o State Engine.
- **tmux Collector** (fallback) — quando não há adapter nativo: `tmux capture-pane` para
  ler e `tmux send-keys` para escrever; detecção por heurística de texto.
- **State Engine** — consome eventos (nativos, precisos; ou tmux, heurísticos) e move cada
  sessão pela máquina de estados. Decide quando disparar notificação.
- **Notifier (APNs)** — nas transições relevantes, monta o push com o tipo de haptic e o
  metadado, e envia à Apple. Guarda a credencial `.p8`.
- **Command API (WebSocket + REST)** — a superfície que o app consome: listar sessões,
  assinar stream de output, enviar texto/teclas, lançar tarefa, aprovar/negar prompt.

## Contratos entre componentes

- **Adapter → State Engine:** eventos normalizados (`session_started`, `output_chunk`,
  `needs_input`, `permission_requested`, `finished`, `errored`), independentes do agente.
- **State Engine → Notifier:** transições relevantes (`→ needs_you`, `→ done`, `→ error`)
  com metadado mínimo.
- **Command API → Adapter:** comandos (`launch`, `send_text`, `approve`, `deny`).
- **Registry:** consultado/atualizado por todos; nunca escrito por dois componentes para o
  mesmo campo sem passar pelo State Engine.

Detalhe da máquina de estados em [03 — Modelo de estado](03-modelo-de-estado.md).
