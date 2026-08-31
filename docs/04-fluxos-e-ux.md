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

## Fluxo: ler no aparelho — 2026-08-31

Seção nova, escrita depois da leva 2.9.0. Os fluxos acima descrevem **decidir** de longe;
este descreve **entender** de longe, que é outra coisa e tinha ficado de fora: o pedido
que a originou foi "meu iPhone consiga visualizar bastante contexto, ler e entender melhor
sem precisar pedir pra resumir" e "o iPad consiga substituir ter que voltar pro PC pra
visualizar melhor um trecho de código ou a resposta da IA".

**Três regras valem em todas as superfícies de leitura** (chat do app, visualizador de
arquivo, diff, e as mesmas telas no dashboard web):

1. **A tela só rola sozinha para quem já estava no fim.** Quem subiu para reler fica onde
   está e recebe um aviso de quantas mensagens novas chegaram. Antes o transcrito rolava a
   cada item novo: numa sessão viva, subir para reler durava até o próximo chunk — era a
   razão prática de "não dá pra ler no celular, tenho que pedir pra resumir". A folga de
   "estar no fim" é generosa de propósito (40 pt), para rolagem elástica e arredondamento
   não passarem por "a usuária subiu".
2. **Tamanho de texto é ajustável e separado por classe de aparelho.** No iPhone o ajuste
   costuma ser para baixo (caber mais contexto), no iPad para cima (ler à distância) — uma
   chave de preferência para cada. No chat o valor guardado é um **deslocamento** sobre o
   Dynamic Type do sistema, nunca um tamanho absoluto: quem configurou o aparelho inteiro
   em texto grande continua recebendo texto grande.
3. **Ler é achar.** Visualizador de arquivo e diff têm busca com contador ("3 de 12") e
   navegação circular entre as ocorrências. Sem isso, achar uma função num arquivo de 2 mil
   linhas continua sendo motivo para voltar ao computador — que é justamente o que a leva
   queria eliminar.

**Quanto contexto cabe:** 2000 mensagens por sessão, o mesmo número no hub e no app (ver
[02 — Arquitetura](02-arquitetura.md), seção "Retenção de output por sessão").

**Teclado no iPad**, para as abas se comportarem como as do navegador: `⌘⇧]` e `⌘⇧[`
andam entre abas (circular), `⌘W` fecha e `⌘⌥T` reabre a última fechada. O `⌘⇧T` de
costume **não** foi usado: ele já era "Próximo painel" desde a versão iPad, e trocar um
atalho que já está no dedo custa mais do que ganhar o padrão. A pilha de reabertura vive só
em memória — desfazer um fechamento é arrependimento imediato, não histórico.

> **Exceção documentada:** o visualizador de arquivo renderiza o conteúdo num `Text` único
> para preservar a seleção contínua. O **modo linha** (numeração ou busca ativa) quebra essa
> regra porque não existe âncora de rolagem dentro de um `Text` só — por isso ele é sempre
> **pedido**, e sai sozinho quando a busca é limpa.
