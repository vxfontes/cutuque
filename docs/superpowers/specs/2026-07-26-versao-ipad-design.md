# Versão iPad do Cutuque — design

_2026-07-26 · autora: Vanessa (decisões) + /cutuque (redação)_

## Objetivo

Levar o app Cutuque ao iPad como cidadão nativo, cobrindo as três superfícies de
trabalho: **terminais tmux**, **chat de sessão** e **board kanban**.

Ambição acordada: **"bem adaptado, mesmo fluxo"** — navegação e conceitos iguais
aos do iPhone, porém no idioma do iPad, com **um painel de conteúdo por vez**.
Não é uma estação multi-janela; é o mesmo app, confortável numa tela grande e com
teclado físico.

O iPhone continua sendo o controle remoto de bolso. O iPad passa a ser onde dá pra
acompanhar um build inteiro sem a TUI do Claude re-quebrar.

## Ponto de partida (verificado no código em 2026-07-26)

O app **não declara o iPad como destino**: `TARGETED_DEVICE_FAMILY: "1"` em
`app/project.yml:58` (CutuqueApp) e `:108` (CutuqueWidgets). No iPad ele roda
apenas escalado.

As três superfícies **já existem** — este projeto é adaptação, não construção:

| Arquivo | Linhas | Papel |
|---|---|---|
| `SessionDetailView.swift` | 1041 | chat da sessão |
| `BoardView.swift` | 663 | board kanban + detalhe + arquivo |
| `TerminalMirrorView.swift` | 488 | espelho tmux interativo |
| `SessionListView.swift` | 881 | lista de sessões |

O que não escala pro iPad é a **navegação**: raiz é `TabView` (Sessões / Board),
e terminal, nova sessão, ajustes, histórico, detalhe de card e arquivo são todos
`sheet`.

### Restrições apuradas no código

1. **O terminal não é um PTY.** `TerminalMirrorModel` faz polling: `start()`
   captura a tela a cada **1,5 s**; `sendKey()` é round-trip HTTP + `sleep(250 ms)`
   + refresh; `send()` idem com 350 ms. Digitação caractere-a-caractere está
   descartada por construção.
2. **O terminal redimensiona o pane remoto a partir da largura da view.**
   `cols = (largura − 16) / (fonte × 0.62)`, dentro de um
   `.task(id: "\(cols)x\(rows)")` que chama `tmuxResize`.
3. **"Encalhadas" não é uma coluna.** É o predicado `encalhada == true`;
   `BoardModel.inColumn(.aFazer)` exclui esses cards da primeira coluna.
   `setBoardEncalhada(true)` força `column: "a_fazer"` no corpo da requisição.
4. **O board não tem WebSocket.** Toda ação faz `await api.…` seguido de
   `await load()`, que recarrega o board inteiro.
5. **`horizontalSizeClass` é `.regular` nas duas orientações** em iPad de tela
   cheia — não serve para distinguir retrato de paisagem.
6. **Não existe nenhum teste automatizado** em `app/`.

### Ambiente: desbloqueado (corrige a memória)

As notas de 19/07 e 21/07 registram build bloqueado por falta de runtime de
simulador. **Não procede mais.** Verificado hoje:

- `xcrun simctl runtime list` → iOS 26.3.1 e watchOS 26.2, ambos `Ready`
- `xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet` → **exit 0, 0 erros**

Resta apenas o warning pré-existente de `PushManager.swift:65` (`timeSensitive`
deprecado), sem relação com este trabalho.

Pendência pequena: os runtimes existem mas **nenhum aparelho de simulador foi
criado** (`simctl list devices` volta vazio). Os device types de iPad Pro M4/M5
estão disponíveis.

## Arquitetura de navegação

Uma `NavigationSplitView` de três colunas, **construída uma vez e nunca
substituída**. Trocar de destino troca o que as closures `content:` e `detail:`
devolvem; o SwiftUI atualiza o corpo em vez de recriar a árvore.

```
CutuqueApp
└── RootSplitView                          [novo — substitui RootTabView]
    └── NavigationSplitView(columnVisibility: $cols)
        ├── sidebar: DestinationSidebar    [novo]
        │            Sessões · Board · Histórico · Arquivo · Hub · Ajustes
        ├── content:
        │     ├── Sessões → SessionListView      [adaptada: perde a NavigationStack própria]
        │     └── Board   → BoardFilterList      [novo: a FilterBar horizontal vira lista]
        └── detail:
              ├── Sessões → SessionDetailPane    [novo: seletor Chat | Terminal]
              │              ├── SessionDetailView   [intacta]
              │              └── TerminalMirrorView  [intacta + teclado]
              └── Board   → BoardView             [adaptada: colunas lado a lado]
                             └── .inspector → BoardTaskDetailView  [era sheet]
```

**Por que uma instância só:** girar o iPad muda apenas `columnVisibility`, que é
estado, não estrutura. O `TerminalMirrorModel` sobrevive e o `onDisappear` que
faz `stop()` + `restoreSize()` não dispara. Trocar a raiz entre `TabView` e
`NavigationSplitView` conforme a orientação — considerado e **rejeitado** —
derrubaria o espelho do tmux, redimensionaria o pane remoto e perderia a rolagem
do chat a cada rotação.

### Orientação

Comportamento nativo do `NavigationSplitView`: em paisagem as três colunas ficam
visíveis; em retrato a sidebar recolhe e volta pelo botão ☰. Não há código de
orientação — é o padrão do componente.

A pedida original era `TabView` em retrato e `NavigationSplitView` em paisagem.
Foi substituída por esta forma depois de discutido o custo de remontagem.
Acrescentar uma tab bar só em retrato continua possível depois, como mudança
isolada, sem mexer na raiz.

### Regra de largura (vale para board e terminal)

Ambas as superfícies largas sofrem no 11". O kanban em detalhe de ~554 pt fica
com ~110 pt por coluna (título de card quebrando em três linhas), e o terminal
com a fonte nova cai abaixo das 80 colunas clássicas.

**Regra única:** quando o detalhe seria menor que **700 pt**, os destinos que
precisam de largura — Board e Terminal — abrem já expandidos
(`columnVisibility = .detailOnly`). Acima disso, abrem em três colunas.

Na prática: iPad 11" abre expandido, iPad 13" abre em três colunas. O app escolhe
apenas o **primeiro** estado; o botão ⤡ recolhe e expande a qualquer momento, e a
escolha manual vale até trocar de destino.

## Terminal

Mora no painel de detalhe, sob o seletor **Chat | Terminal**. O botão ⤡ recolhe
as colunas para largura de monitor.

Colunas resultantes, já com a fonte padrão de cada plataforma (10 pt no iPhone,
13 pt no iPad — ver mudança 3 abaixo). Em **negrito**, o estado inicial que a
regra de 700 pt escolhe:

| Contexto | Fonte | Largura útil | Colunas |
|---|---|---|---|
| iPhone 15 Pro retrato (hoje) | 10 pt | 393 pt | ~60 |
| iPad 11", três colunas | 13 pt | ~554 pt | ~67 |
| **iPad 11", expandido** | 13 pt | 1194 pt | **~146** |
| **iPad 13", três colunas** | 13 pt | ~726 pt | **~88** |
| iPad 13", expandido | 13 pt | 1366 pt | ~167 |

Referência: terminal clássico são 80 colunas; a TUI do Claude fica confortável
entre 100 e 120.

É exatamente por isso que a regra de 700 pt existe: no 11" em três colunas o
terminal cairia para ~67 colunas — **pior que um terminal clássico**. Abrindo
expandido, vai para ~146.

### Mudanças no espelho

1. **Debounce de resize (~300 ms).** O `.task(id:)` atual dispara `tmuxResize` a
   cada mudança de largura. No iPad a largura muda em rotação, no ⤡ e — pior —
   durante o arraste do divisor do Split View, que geraria dezenas de POSTs
   seguidos. Debounce no par `(cols, rows)`, ignorando valor repetido.
2. **`stop()` e `restoreSize()` deixam de ser a mesma coisa.** Sair de vista
   (trocar para o destino Board) para o poll e poupa bateria; `restoreSize()`
   passa a ocorrer só ao fechar a sessão de verdade. Hoje ambos moram no mesmo
   `onDisappear`, que não previa "sair de vista sem fechar".
3. **Fonte por classe de tela.** Nova chave `cutuque.terminalFont.pad`, separada
   da atual, com padrão **13 pt** no iPad. Os 10 pt de hoje foram calibrados para
   os 393 pt do iPhone; num detalhe de 726 pt viram letra miúda demais para ler
   de braço estendido. O par 13 pt + regra de 700 pt entrega ~88 colunas no 13"
   em três colunas e ~146 no 11" expandido (tabela acima).
4. **Poll adaptativo.** 1,5 s → 3 s quando a tela não muda há 30 s; volta a 1,5 s
   no primeiro diff. Uma tela de 220×60 é ~13 KB por captura contra ~4 KB hoje.

## Teclado físico

Uma regra, sem modo escondido:

- **Caracteres imprimíveis** vão para a barra de input local — instantâneo, zero
  rede. `⏎` envia a linha via `send()`.
- **Teclas de semântica de terminal** — `esc`, `⌃C`, `⇥`, `↑ ↓ ← →` — são
  encaminhadas direto via `sendKey()`, mesmo com o cursor na linha. Na TUI do
  Claude as setas navegam menu e histórico. Mover o cursor dentro da linha fica
  com `⌥←` / `⌥→`.

São as mesmas teclas da `keyBar` de hoje, agora também pelo teclado físico. A
`keyBar` na tela permanece, para uso sem teclado.

### Atalhos de comando

| Atalho | Ação | Escopo |
|---|---|---|
| `⌘⇧T` | alternar Chat ↔ Terminal | detalhe da sessão |
| `⌘⏎` | enviar | chat e terminal |
| `⌘.` | parar o agente (`POST /sessions/{id}/interrupt`) | sessão |
| `⌘⌃F` | recolher / expandir colunas (o ⤡) | global |
| `⌘+` `⌘−` | fonte do terminal | terminal |
| `⌘1`…`⌘9` | ir para a n-ésima sessão | global |
| `⌘0` | ir para o Board | global |
| `⌘F` | buscar | board |
| `⌘R` | recarregar | global |
| `⌘N` | nova sessão | global |

Via `.keyboardShortcut`, que alimenta o menu de atalhos do iPadOS (segurar `⌘`)
sem código extra. As teclas de terminal via `.onKeyPress`. Ambos são iOS 17 — o
alvo atual não sobe.

## Board

Kanban ocupa toda a largura ao lado da sidebar. Filtros na coluna do meio.
Detalhe do card em `.inspector()` (iOS 17) no lugar de `sheet`.

### Semântica do arrastar

| De | Para | Efeito |
|---|---|---|
| coluna normal | coluna normal | `move(to:)` — uma chamada |
| qualquer | **Encalhadas** | `setBoardEncalhada(true)` — já força `column: "a_fazer"` |
| **Encalhadas** | coluna normal | `move(to:)` — uma chamada; o hub limpa a flag sozinho |
| arquivado | qualquer | bloqueado — `archived == true` não é arrastável |
| qualquer | arquivado | não existe — o arquivo nunca é alvo de drop |

Verificado no hub: `postgres.go:281` faz `SET column_name=$2, encalhada=false, …`
no move, com testes cobrindo (`board_test.go:111` e `:219`). Sair de Encalhadas
não precisa de segunda chamada.

### Movimento otimista

Hoje `move` faz `api.moveBoardTask` seguido de `load()` do board inteiro. Num
toque de botão isso passa; num arraste o card voltaria visivelmente à origem
antes de reaparecer no destino.

`BoardTask.column` é `var`, então: mutar `tasks` localmente, disparar a chamada,
reconciliar em silêncio no sucesso, reverter e avisar no erro. O caminho antigo
permanece intacto para o botão do inspector.

### Busca

Hoje a busca substitui o board inteiro (`isSearching ? searchResultsView :
boardScroller`). Passa a ocupar apenas a coluna do meio: o kanban continua
visível atrás, e selecionar um resultado abre o card no inspector e o destaca na
coluna onde está. `searchBoard` já cobre título, descrição e comentários,
incluindo arquivados — que vêm marcados e abrem só-leitura.

### O que era sheet

| Hoje | No iPad |
|---|---|
| `sheet(item: $selected)` → detalhe do card | `.inspector()` à direita |
| `sheet(isPresented: $showArchive)` → arquivo | destino na sidebar |
| `FilterBar` horizontal (grupo / tipo / sessão) | lista na coluna do meio, três eixos visíveis juntos |
| "Fechar semana" no menu `•••` | permanece, com o mesmo `alert` |

Apagar card e fechar semana continuam ações explícitas com confirmação. Nenhuma
das duas passa a acontecer por arraste.

### Teclado no board

`⌘F` busca · `⌘R` recarrega · `↑↓` anda nos cards da coluna · `←→` troca de
coluna · `⌘←` `⌘→` **move** o card selecionado (mesmo caminho otimista do
arraste) · `esc` fecha o inspector.

## Riscos

| Risco | Severidade | Mitigação |
|---|---|---|
| Tempestade de `tmuxResize` durante arraste do divisor do Split View | **Alto** | debounce de ~300 ms; ignorar valor repetido |
| `restoreSize()` disparando ao só trocar de destino | Médio | separar `stop()` de `restoreSize()` |
| Layout quebrando em Slide Over (~320 pt, `horizontalSizeClass` compacto) | Médio | teste explícito de chat e terminal em largura reduzida |
| App Review passa a testar em iPad; capturas de iPad viram obrigatórias; `NSAllowsArbitraryLoads` mais exposto | Médio | não bloqueia dev nem TestFlight; tratar junto com o ATS antes de submeter |
| Zero testes automatizados no app | Médio | extrair move otimista e debounce como funções puras e cobrir; não montar suíte de UI test aqui |
| Remontagem acidental da split view | Baixo | critério de aceite da fase 1: girar com terminal aberto sem derrubar o pane |

## Fora de escopo

Múltiplas janelas e múltiplas instâncias no Stage Manager · Apple Pencil ·
monitor externo · arrastar cards para fora do app · Catalyst/macOS · reescrever o
terminal como PTY real. Nada disso fica impedido pelo design; apenas não entra
agora.

## Fases

Cada fase é entregável sozinha — dá para parar em qualquer uma com o app
funcionando.

| # | Fase | Critério de aceite |
|---|---|---|
| 0 | Família `"1,2"` nos dois targets; criar simuladores 11" e 13" | app abre nativo em ambos, sem crash, ainda com layout de iPhone |
| 1 | `RootSplitView` + `DestinationSidebar` + `SessionListView`/`SessionDetailPane` | girar com terminal aberto não derruba o pane nem perde a rolagem do chat |
| 2 | Terminal: debounce, fonte por classe de tela, ⤡, poll adaptativo | arrastar o divisor do Split View gera **1** resize, não dezenas |
| 3 | Teclado físico: `.onKeyPress` + atalhos `⌘` | esc/⌃C/⇥/setas chegam no tmux; letras ficam na linha; menu do `⌘` lista os atalhos |
| 4 | Board: colunas lado a lado, inspector, filtros na coluna do meio | card abre sem tapar o board; três eixos de filtro visíveis juntos |
| 5 | Board: drag & drop otimista + `⌘←`/`⌘→` | card fica no destino na hora; falha reverte e avisa; arquivado não arrasta |
| 6 | Compact: Slide Over e Split View estreito | chat e terminal usáveis em ~320 pt |

## Decisões travadas nesta rodada

1. **Uma `NavigationSplitView` de três colunas, nunca substituída** — em vez de
   trocar a raiz por orientação. Motivo: preservar o terminal vivo e a rolagem do
   chat na rotação.
2. **Terminal no detalhe com botão de expandir** — em vez de sempre em tela
   cheia. Motivo: 89–117 colunas já bastam para a TUI; a expansão fica como
   escolha por momento.
3. **Teclado físico dentro do escopo**, com linha composta localmente e teclas
   especiais encaminhadas. Motivo: o espelho é por polling; digitação
   caractere-a-caractere custaria ~250 ms por letra.
4. **Drag & drop no board, com movimento otimista.** Motivo: o gesto que o
   layout lado a lado pede, e a API de mover já existe.
