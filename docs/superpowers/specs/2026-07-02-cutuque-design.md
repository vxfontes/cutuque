# Cutuque — Design

**Data:** 2026-07-02
**Status:** Design aprovado (aguardando revisão final do spec)

## Resumo

Cutuque é um painel de controle remoto, com notificações hápticas, para agentes de
terminal (Claude Code, Codex, OpenCode) que rodam em máquinas pessoais distribuídas.
O usuário opera tudo pelo iPhone e Apple Watch: dispara tarefas, acompanha o output ao
vivo, aprova pedidos de permissão e é avisado por vibração no pulso quando algo conclui
ou precisa de atenção — de qualquer lugar, via Tailscale, sem depender de nuvem de
terceiros.

O nome vem de "cutucar": o cutucão no pulso te chamando quando um agente precisa de você.

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
- **Hub:** servidor local em `192.0.2.10` (Tailscale), sempre ligado, com internet de saída.
- **Máquinas-alvo:**
  - MacBook (uso principal) — tmux nativo.
  - Desktop Windows (reserva p/ viagens) — agentes rodam em tmux **dentro do WSL2**;
    Tailscale + sshd no WSL2 fazem dele "só mais um alvo" idêntico ao Mac.
- **Cliente:** app nativo iOS + watchOS (SwiftUI). Licença Apple disponível para publicação.
- **Linguagem do hub:** Go (binário único, forte em concorrência e SSH).

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

Cada componente tem uma responsabilidade única e um contrato claro.

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

## Modelo de estado da sessão

| Estado | Significado | Ação no app | Dispara push? |
|--------|-------------|-------------|:---:|
| `running` | agente trabalhando | acompanhar output | não |
| `needs_you` | pediu permissão / fez pergunta / travou esperando input | responder/aprovar | **sim** |
| `done` | tarefa concluída | revisar resultado | **sim** |
| `error` | crashou / erro | investigar | **sim** |
| `idle` | sessão viva, sem tarefa ativa | disparar novo prompt | não |

As transições para `needs_you`, `done` e `error` disparam notificação + haptic.
A precisão da transição depende do canal: nativo = evento exato; tmux = heurística de texto.

## Fluxo de "aprovar de longe"

1. Agente emite um pedido de permissão (ex.: "permitir editar arquivo X?").
2. Adapter detecta (via hook nativo quando possível) e captura o **contexto** (texto do prompt).
3. State Engine move a sessão para `needs_you` e o Notifier dispara push.
4. Watch vibra (padrão insistente) e mostra ações rápidas: **Aprovar / Negar / Abrir no iPhone**.
5. Usuário decide → app envia a ação ao hub → hub responde ao agente pelo canal nativo
   (ou, no fallback, injeta a tecla via `tmux send-keys`).

**Invariante de segurança:** o app SEMPRE mostra o texto do prompt antes da decisão.
Nunca se aprova às cegas.

## Experiência no Watch + haptics

O Watch mostra **estado e decisão rápida**, não código.

- `done` → haptic suave duplo + "✅ [sessão] concluiu".
- `needs_you` → haptic insistente/mais forte + "⚠️ [sessão] precisa de você" com ações rápidas.
- `error` → haptic staccato distinto + "❌ [sessão] falhou".
- App watchOS: lista de sessões com bolinha de cor por estado; tocar em `needs_you` mostra
  a pergunta + botões.

Implementação: `WKInterfaceDevice.play(_:)` no app + categorias de notificação do APNs
para as ações no pulso.

## Segurança

- Hub escuta **apenas na interface Tailscale** — nunca exposto à internet pública.
- **Token bearer por device** no WebSocket/REST, além da identidade da Tailscale.
- Credencial **APNs (.p8)** só no hub, nunca embarcada no app.
- Output de código trafega **só na Tailscale** (alvo → hub → app). No APNs vai apenas
  metadado ("sessão X concluiu"), zero código.
- **A decidir:** mTLS além do token bearer (avaliar custo/benefício dado que já é Tailscale-only).

## Tratamento de erros

- **Alvo inacessível** (máquina offline / fora da Tailscale) — sessões marcadas como
  indisponíveis no Registry; app mostra estado degradado, não trava.
- **Falha ao entregar push** — o estado real permanece no hub; ao abrir o app, o usuário vê
  o estado correto mesmo que o push tenha se perdido (o push é conveniência, não a verdade).
- **Detecção tmux ambígua** — na dúvida, preferir `needs_you` (chamar o usuário) a assumir
  `done` erroneamente. Errar para o lado de avisar.
- **Ação de aprovação em sessão que já mudou de estado** — hub valida o estado atual antes
  de aplicar; ação obsoleta é rejeitada com feedback no app.

## Estratégia de testes

- **Adapters** — testados contra saídas gravadas de cada agente (fixtures de
  `stream-json`, respostas HTTP do OpenCode, JSON do `codex exec`).
- **State Engine** — testes de tabela cobrindo todas as transições da máquina de estados,
  incluindo casos ambíguos do fallback tmux.
- **Command API** — testes de contrato (WebSocket/REST) com um app cliente fake.
- **Notifier** — mock do APNs; verificar mapeamento estado → tipo de haptic + metadado.
- **App iOS/watchOS** — testes de UI dos fluxos principais (lista, aprovar, disparar).
- **End-to-end** — cenário do MacBook: lançar tarefa pelo app → observar → aprovar → receber
  aviso de conclusão.

## Corte de MVP

### v0 — usar todo dia com o mínimo
- Hub em Go.
- Adapter nativo do **Claude Code** no MacBook (headless/SDK + hooks): **lançar** e observar.
- Notifier APNs.
- App iOS mínimo: lista de sessões, ver output, **disparar tarefa**, aprovar/negar.
- Notificação no Watch com haptic (espelhada da notificação do iPhone; sem app watchOS ainda).

### v1
- App watchOS nativo com ações rápidas no pulso.
- Fallback tmux (cobertura universal).
- Adapters de Codex e OpenCode.

### v2
- Alvo Windows/WSL2.
- Haptics customizados por tipo de evento.
- Histórico de sessões.

## Pendências

- mTLS além do token bearer?
- Puxar o app watchOS nativo do v1 para o v0?

## Próximo passo

Escrever o plano de implementação (writing-plans) a partir do corte de v0.
