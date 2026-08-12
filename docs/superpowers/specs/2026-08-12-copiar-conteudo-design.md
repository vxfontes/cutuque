# Copiar conteúdo no iPad e no iPhone — design

**Data:** 12/08/2026
**Autor:** /cutuque (orquestrador)
**Card do board:** `65368a7ea4cf426b`

## O problema, nas palavras da usuária

> "nos dois dispositivos eu tenho problema pra copiar itens: tanto em chats
> quanto em terminais eu não consigo copiar direito alguma coisa. Isso dificulta
> um pouco quando eu preciso passar um conteúdo do aplicativo pra, por exemplo,
> meu WhatsApp pra conversar com alguém e eu não estou com computador perto."

O caso de uso é **exportar para fora do app**: pegar uma resposta do agente, um
comando com seu resultado, ou o que está na tela do terminal, e colar no
WhatsApp. Hoje isso não funciona em nenhuma das três superfícies — e por três
causas diferentes. Não é um bug; são três.

## Diagnóstico — três causas independentes

### 1. Chat: o texto está picado em dezenas de `Text`

`MarkdownText.swift` renderiza `ForEach(MarkdownBlock.parse(text))` (linha 14) —
**um `Text` por bloco**. `.textSelection(.enabled)` só seleciona dentro de UM
`Text`: a seleção não atravessa bloco. E, no caso de um diff, `diffBody` pica
ainda mais fino — **um `Text` por linha** (linhas 101-105), para colorir `+`/`-`
— então nem dentro do bloco a seleção anda. O `.textSelection(.enabled)` que
`assistantBlock` põe por fora (`SessionDetailView.swift:950`) não faz nada útil,
porque quem manda é o `Text` folha.

Consequência prática: um bloco de código simples é um `Text` só (linha 87) e dá
para copiar arrastando; um diff dá para arrastar apenas dentro de uma linha; e
uma resposta do agente com prosa + código nunca sai inteira, porque são blocos
diferentes.

Detalhe que muda o desenho: o cabeçalho do bloco de código só é renderizado
`if !lang.isEmpty || isDiff` (linha 77). Um bloco cercado sem linguagem —
comuníssimo na saída do agente — não tem cabeçalho nenhum. Pendurar o botão de
copiar no cabeçalho existente deixaria justamente esses blocos de fora, então o
cabeçalho passa a existir sempre que houver bloco de código; o que é opcional é
o rótulo da linguagem, não a barra.

### 2. Espelho tmux ao vivo: a seleção morre a cada quadro

`TerminalMirrorView.swift` é um `Text` único (linha 478) — o que seria bom —
mas `model.screen` é `@Published` e chega do WebSocket **a cada atualização da
tela**. Toda republicação recria o `Text` e a seleção em curso é descartada.
Pior: existe um `withAnimation` de auto-scroll no `.onChange(of: model.screen)`
(~linha 397), que também interrompe o gesto.

Consequência: num terminal parado dá para selecionar; num terminal vivo
(justamente onde ela quer copiar a saída de um comando) a seleção evapora.

### 3. Terminal ssh (SwiftTerm): o gesto é comido antes de chegar na seleção

`PTYTerminalView` é um `UIViewRepresentable` de `TerminalView` do SwiftTerm.
Duas coisas se somam:

- `allowMouseReporting` nasce `true` (`iOS/iOSTerminalView.swift:149`) e os
  guardas de mouse-reporting (linhas 800, 851, 876, 972) desviam os gestos
  para o programa que roda dentro do terminal, antes de virarem seleção.
- O menu de copiar do SwiftTerm no iOS usa `UIMenuController`
  (`iOSTerminalView.swift:629`), depreciado desde o iOS 16 — em iOS 17/18 ele
  aparece de forma errática ou não aparece.

Consequência: `copy(_:)` existe (`iOSTerminalView.swift:560`), mas na prática a
usuária não consegue chegar até ele.

## Decisões tomadas (respostas da usuária)

| Pergunta | Resposta |
|---|---|
| Gesto | **Os dois**: copiar-a-coisa-inteira em um toque **e** seleção parcial precisa |
| Destino | **Só copiar** (área de transferência). Sem `ShareLink` por ora |
| Superfícies | **Todas as três**: chat, espelho tmux ao vivo, terminal ssh |
| Alcance no terminal | **Só a tela visível.** Sem scrollback, sem mexer no hub Go |

Acrescentar "Compartilhar" depois custa ~uma linha por superfície (trocar o
`Button` por um `ShareLink` com o mesmo texto). Fica registrado, não entra agora.

## A arquitetura: uma folha congelada + dois gestos por superfície

A ideia central é não brigar com nenhuma das três causas. As três têm a mesma
raiz — **o texto que está na tela não é um alvo estável de seleção** — e a mesma
saída: quando a usuária quer selecionar com precisão, o app abre uma **folha com
um retrato imóvel do texto**. Retrato imóvel = nada republica, nada anima, nada
está picado em `Text` por linha. A seleção nativa do iOS funciona 100% ali, com
lupa, alças e o menu Copiar do sistema.

E quando ela quer só a coisa inteira, um toque resolve, sem seleção nenhuma.

Então cada superfície ganha exatamente **dois** caminhos:

1. **Copiar inteiro** — um toque. Vai direto para a área de transferência.
2. **Selecionar texto…** — abre a folha congelada com aquele conteúdo.

```
                    ┌─────────────────────────────┐
   chat  ──────────►│                             │
   espelho tmux ───►│   FolhaDeTexto (congelada)  │──► seleção nativa + Copiar
   terminal ssh ───►│   Text(texto) imóvel        │
                    └─────────────────────────────┘
                             ▲
                             │ texto plano, já aparado
                    Ansi.plain / TextoParaCopiar
```

### Peças compartilhadas (onda 1)

**`Ansi.plain(_:)`** em `AnsiRenderer.swift` — devolve o texto **sem** as
sequências ANSI. Implementada em cima de `Ansi.attributed`, extraindo os
`characters` da `AttributedString`, **não** com um segundo varredor de ANSI: dois
varredores divergem com o tempo, e o do `attributed` já é o testado em produção.

```swift
static func plain(_ input: String) -> String
```

**`app/CutuqueApp/CopiarTexto.swift`** (arquivo novo) com três coisas:

```swift
enum AreaDeTransferencia {
    static func copiar(_ texto: String)          // UIPasteboard.general.string
}

enum TextoParaCopiar {
    /// Apara espaço à direita de cada linha e linhas em branco no fim.
    static func aparado(_ texto: String) -> String
    /// A seleção da usuária quando existe; senão a tela visível inteira.
    static func doTerminal(selecionado: String?, tela: String) -> String
    /// Uma tool call e seu resultado, como ela leria num terminal.
    static func deFerramenta(comando: String, resultado: String?) -> String
}

struct FolhaDeTexto: View {                       // a folha congelada
    let titulo: String
    let texto: String
    var monoespacado: Bool = false
}
```

`aparado` não é detalhe: a tela de um terminal é uma matriz 80×24 preenchida com
espaços. Copiar cru cola no WhatsApp 15 linhas vazias e um monte de espaço à
direita. Aparar é o que faz o resultado ser colável.

`deFerramenta` existe para o caso `.tool` do chat, onde o que a usuária quer não
é "o comando" nem "o resultado", e sim os dois como ela leria: `$ comando`,
depois a saída. E vive nas peças compartilhadas justamente porque `ChatItem` é
`private` dentro de `SessionDetailView.swift` — a regra pura fica sobre
`String`, e portanto testável, sem precisar expor o tipo privado.

### Superfície 1 — Chat

- **Um toque:** o cabeçalho do bloco de código (`MarkdownText.swift:78`, que já
  mostra o rótulo da linguagem) ganha um botão de copiar à direita. Copia o
  código cru daquele bloco. É o gesto mais pedido: copiar um comando que o
  agente sugeriu.
- **Toque longo:** um `.contextMenu` no funil `chatItemView`
  (`SessionDetailView.swift:918`) — o único lugar por onde passam os três tipos
  de item — com **Copiar** e **Selecionar texto…**. O menu no funil vale para
  bolha da usuária, resposta do agente e tool call, sem repetir código três
  vezes, e usa o texto **cru** de `ChatItem.content` (não o renderizado).

### Superfície 2 — Espelho tmux ao vivo

O menu de tema que já existe na toolbar (`TerminalMirrorView.swift:367-375`)
ganha dois itens: **Copiar tela** e **Selecionar texto…**. Os dois usam
`TextoParaCopiar.aparado(Ansi.plain(model.screen))` — o retrato do
`model.screen` **no instante do toque**. É exatamente por isso que funciona: o
que vai para a folha é uma `String` copiada, não o `@Published`; ela não muda
mais, mesmo que o terminal continue vivo atrás.

### Superfície 3 — Terminal ssh (SwiftTerm)

Nada de mexer no `allowMouseReporting` nem no `UIMenuController`. Em vez disso o
app passa a **ler** o `TerminalView` de fora, com APIs públicas que confirmei na
fonte do pacote:

| O que preciso | API pública |
|---|---|
| o terminal | `TerminalView.getTerminal() -> Terminal` |
| seleção ativa? | `TerminalView.selection.active` |
| texto selecionado | `TerminalView.selection.getSelectedText()` |
| primeira linha visível | `terminal.buffer.yDisp` |
| tamanho da tela | `terminal.rows`, `terminal.cols` |
| texto de um trecho | `terminal.getText(start: Position, end: Position)` |

A tela visível é `yDisp ..< yDisp + rows`. Como `Terminal.displayBuffer` é
apenas `buffer` (linha 392-394 de `Terminal.swift`), o `getText` público lê
exatamente o buffer que está sendo exibido — inclusive na tela alternativa, que
é onde tmux e vim vivem.

Para o SwiftUI alcançar isso, `PTYTerminalView` recebe uma **ponte** magra:

```swift
/// Deixa a tela LER o terminal sem virar dona dele.
final class TerminalTexto {
    weak var view: TerminalView?
    func telaVisivel() -> String
    func selecionado() -> String?
}
```

`weak` de propósito: a ponte não pode manter o `TerminalView` vivo depois do
`dismantleUIView`. `MachineDetailView` cria a ponte, passa para
`PTYTerminalView`, e a toolbar ganha os mesmos dois itens das outras
superfícies. Se a usuária conseguiu selecionar algo dentro do SwiftTerm (às
vezes consegue), **Copiar tela** respeita a seleção dela; senão copia a tela —
é o que `TextoParaCopiar.doTerminal(selecionado:tela:)` decide.

## Erros e casos de borda

- **Terminal vazio / ainda conectando:** copiar não faz nada e não abre folha
  vazia; o item fica desabilitado quando o texto aparado é vazio.
- **Cancelamento e ciclo de vida:** a ponte é `weak`; se a aba foi liberada
  (decisão #19: a aba fica montada, mas o terminal pode ter sido derrubado),
  `view` é `nil` e as leituras devolvem vazio, sem crash.
- **Aba montada para sempre:** nada aqui usa `.onDisappear` — pela decisão #19,
  `.onDisappear` nunca dispara dentro de uma aba.
- **Sem retorno visual, a usuária toca duas vezes:** o botão de copiar troca
  para um `checkmark` por ~1,5 s. Sem isso ela não tem como saber que copiou.
- **Sequências ANSI no chat:** o chat não tem ANSI (o hub já manda texto),
  então `Ansi.plain` fica restrito às duas superfícies de terminal.

## Testes

O que é regra pura vira teste de unidade (padrão da casa: decisão pura fora da
View):

- `Ansi.plain` — texto sem ANSI passa igual; cores SGR desaparecem; 256 e
  truecolor desaparecem; sequência não-SGR (mover cursor, limpar) desaparece;
  o par que importa: `plain` de uma entrada colorida == o texto que
  `attributed` mostraria.
- `TextoParaCopiar.aparado` — apara espaço à direita, apara linhas vazias do
  fim, **preserva** linha vazia no meio (parágrafo é informação), texto só de
  espaços vira vazio.
- `TextoParaCopiar.doTerminal` — seleção não vazia ganha da tela; seleção `nil`
  ou vazia cai na tela; a tela também vem aparada.
- `TextoParaCopiar.deFerramenta` — comando sem resultado; comando com
  resultado; resultado vazio não deixa linha sobrando.

O que depende de UIKit/SwiftUI (`AreaDeTransferencia`, `FolhaDeTexto`, a ponte
`TerminalTexto`) **não** ganha teste de unidade: é casca de uma linha sobre API
do sistema. Vale a verificação no dispositivo, listada no plano.

## O que este design NÃO faz

- Não copia scrollback — só a tela visível (decisão da usuária).
- Não toca no hub Go.
- Não conserta a fragmentação do `MarkdownText` (seria reescrever o renderizador
  para uma `AttributedString` única; a folha congelada resolve o problema da
  usuária por uma fração do risco).
- Não mexe em `allowMouseReporting` — mouse dentro do ssh continua funcionando.
- Não adiciona `ShareLink`.

## Relacionado

- `memory/cutuque/specs/Specs — Abas no iPad, Novo Terminal tmux e Estado por Agente.md`
- `docs/superpowers/plans/2026-08-12-copiar-conteudo.md`
