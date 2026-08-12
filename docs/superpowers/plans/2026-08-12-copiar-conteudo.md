# Copiar conteúdo no iPad e no iPhone — plano de implementação

> **Para workers:** SUB-SKILL OBRIGATÓRIA: use `superpowers:subagent-driven-development`
> ou `superpowers:executing-plans` para executar task por task. Os passos usam
> checkbox (`- [ ]`).

**Spec:** `docs/superpowers/specs/2026-08-12-copiar-conteudo-design.md`
**Card do board:** `65368a7ea4cf426b`
**Base:** branch `copiar-base` em `574380d` (fase D das abas globais mesclada, suíte 386/386)

**Objetivo:** em chat, espelho tmux e terminal ssh, a usuária consegue (a) copiar
a coisa inteira em um toque e (b) selecionar um trecho com precisão — para colar
fora do app.

**Arquitetura:** cada superfície ganha dois caminhos. "Copiar inteiro" vai direto
para a área de transferência. "Selecionar texto…" abre uma **folha congelada**
com um retrato imóvel do texto, onde a seleção nativa do iOS funciona porque
nada republica, nada anima e nada está picado em vários `Text`. Toda a decisão
pura (aparar, escolher entre seleção e tela, formatar tool call, tirar ANSI) mora
fora das Views e é testada; as Views só ligam fios.

**Stack:** SwiftUI, SwiftTerm (terminal ssh), XCTest. pt-BR em tudo.

## Restrições globais

- **pt-BR** em código, testes, comentários e textos de UI. Sem exceção.
- **Nunca apagar** comentário que documenta bug ou decisão de arquitetura. Se a
  mudança o tornar falso, **reescreva** com a razão nova e a data (12/08/2026).
- **Decisão #19:** uma aba, criada, fica montada para sempre (ZStack + opacity).
  `.onAppear` roda uma vez por aba; **`.onDisappear` NUNCA roda**. Não ponha
  limpeza de recurso em `onDisappear` dentro de aba.
- **Build:** o runtime do watchOS está quebrado na máquina. Sempre
  `app/CutuqueAppNoWatch.xcodeproj`, e o scheme dentro dele é **`CutuqueApp`**,
  não `CutuqueAppNoWatch`.
- **Arquivo `.swift` novo ou renomeado** ⇒ regenerar os DOIS specs:
  `cd app && xcodegen generate && xcodegen generate --spec project-notest-watch.yml`.
- **Comando da suíte** (600 s de timeout, um UDID por worker):
  ```bash
  cd app && xcodebuild test -project CutuqueAppNoWatch.xcodeproj -scheme CutuqueApp \
    -destination 'platform=iOS Simulator,id=<UDID>' -resultBundlePath /tmp/<nome>.xcresult
  xcrun xcresulttool get test-results summary --path /tmp/<nome>.xcresult
  ```
  O `** TEST SUCCEEDED **` do tail **não é prova**: confirme total/falhas no
  `xcresulttool`.
- **`git add` sempre com caminhos explícitos.** NUNCA `git add -A` nem
  `git add .` — `scripts/tmx.sh`, `app/Local.xcconfig`,
  `app/project-notest-watch.yml` e `app/CutuqueAppNoWatch.xcodeproj` são locais
  da usuária e não podem ser commitados.
- **Sem `git push`, sem merge** em outros branches. Cada task commita só no seu.
- **Semáforo de RAM:** a máquina tem 16 GB e o teto do paralelismo é RAM, não
  CPU. Antes de cada `xcodebuild`, espere um slot:
  ```bash
  while [ "$(pgrep -x xcodebuild | wc -l)" -ge 2 ]; do sleep 20; done
  ```

## Estrutura de arquivos

| Arquivo | Responsabilidade | Task |
|---|---|---|
| `app/CutuqueApp/AnsiRenderer.swift` | + `Ansi.plain(_:)`: texto sem ANSI | 1 |
| `app/CutuqueAppTests/AnsiRendererTests.swift` | novo — testa `plain` | 1 |
| `app/CutuqueApp/CopiarTexto.swift` | **novo** — vocabulário de copiar: área de transferência, regras puras, folha congelada, botão | 2 |
| `app/CutuqueAppTests/CopiarTextoTests.swift` | novo — testa as regras puras | 2 |
| `app/CutuqueApp/SessionDetailView.swift` | menu de contexto no funil do chat | 3 |
| `app/CutuqueApp/MarkdownText.swift` | botão de copiar no cabeçalho do bloco de código | 3 |
| `app/CutuqueApp/TerminalMirrorView.swift` | menu de copiar na toolbar do espelho | 4 |
| `app/CutuqueApp/PTYTerminalView.swift` | ponte `TerminalTexto` + `JanelaVisivel` | 5 |
| `app/CutuqueApp/MachineDetailView.swift` | cria a ponte e o menu de copiar | 5 |
| `app/CutuqueAppTests/JanelaVisivelTests.swift` | novo — aritmética da janela visível | 5 |

**Ordem:** tasks 1 e 2 primeiro (as outras consomem). Tasks 3, 4 e 5 são
independentes entre si e rodam em paralelo, cada uma no seu worktree.

---

### Task 1: `Ansi.plain(_:)` — texto sem as sequências ANSI

**Arquivos:**
- Modificar: `app/CutuqueApp/AnsiRenderer.swift` (acrescentar ao `enum Ansi`, depois de `attributed`, antes de `applySGR`)
- Teste: `app/CutuqueAppTests/AnsiRendererTests.swift` (criar)

**Interfaces:**
- Consome: `Ansi.attributed(_:size:defaultColor:)`, que já existe.
- Produz: `Ansi.plain(_ input: String) -> String` — usada pelas tasks 4 e 5.

- [ ] **Passo 1: escrever o teste que falha**

```swift
import XCTest
import SwiftUI
@testable import CutuqueApp

/// `Ansi.attributed` pinta a tela; `Ansi.plain` é para SAIR do app — o texto
/// que vai pra área de transferência e daí pro WhatsApp não pode levar
/// `ESC[32m` no meio.
final class AnsiRendererTests: XCTestCase {

    func testTextoSemAnsiPassaIgual() {
        XCTAssertEqual(Ansi.plain("cutuque: ok"), "cutuque: ok")
    }

    func testCorSgrDesaparece() {
        XCTAssertEqual(Ansi.plain("\u{1B}[32mverde\u{1B}[0m e normal"), "verde e normal")
    }

    func testCor256ETruecolorDesaparecem() {
        XCTAssertEqual(Ansi.plain("\u{1B}[38;5;208mlaranja\u{1B}[0m"), "laranja")
        XCTAssertEqual(Ansi.plain("\u{1B}[38;2;10;20;30mrgb\u{1B}[0m"), "rgb")
    }

    func testSequenciaNaoSgrDesaparece() {
        // Mover cursor e limpar tela não são conteúdo — `attributed` já as
        // descarta, e `plain` herda isso por construção.
        XCTAssertEqual(Ansi.plain("\u{1B}[2J\u{1B}[Hlimpo"), "limpo")
    }

    func testQuebraDeLinhaEEspacoSobrevivem() {
        // A tela de um terminal É espaço e quebra de linha; se `plain` comesse
        // isso, o texto colado no WhatsApp viraria uma linha só.
        XCTAssertEqual(Ansi.plain("a\nb  c\n"), "a\nb  c\n")
    }

    func testPlainEOMesmoTextoQueAttributedMostra() {
        // O par que importa: prova que `plain` não é um segundo varredor de
        // ANSI com regra própria — ele lê o MESMO resultado que a tela mostra.
        let entrada = "\u{1B}[1;31merro\u{1B}[0m: \u{1B}[38;5;42mdetalhe\u{1B}[0m"
        let mostrado = String(Ansi.attributed(entrada, size: 12, defaultColor: .primary).characters)
        XCTAssertEqual(Ansi.plain(entrada), mostrado)
    }
}
```

- [ ] **Passo 2: rodar e VER falhar**

Espere o slot do semáforo e rode. Esperado: falha de compilação, "type 'Ansi'
has no member 'plain'".

- [ ] **Passo 3: implementar o mínimo**

Em `AnsiRenderer.swift`, logo depois do `}` que fecha `attributed`:

```swift
    /// O mesmo texto que `attributed` mostraria, sem os atributos — para SAIR
    /// do app (área de transferência, e daí WhatsApp).
    ///
    /// Construída EM CIMA de `attributed` de propósito, não com um segundo
    /// varredor de ANSI: dois varredores divergem com o tempo, e este aqui já é
    /// o que a usuária vê na tela todo dia. `size` e `defaultColor` são
    /// irrelevantes aqui (os atributos são descartados), daí valores fixos.
    static func plain(_ input: String) -> String {
        String(attributed(input, size: 12, defaultColor: .primary).characters)
    }
```

- [ ] **Passo 4: rodar e ver passar**

Regenere os dois projetos (arquivo de teste novo!) e rode a suíte. Esperado:
386 + 6 = **392 testes, 0 falhas, 0 expectedFailures**, confirmado no
`xcresulttool`.

- [ ] **Passo 5: commit**

```bash
git add app/CutuqueApp/AnsiRenderer.swift app/CutuqueAppTests/AnsiRendererTests.swift
git commit -m "feat(copiar): Ansi.plain — texto de terminal sem as sequencias ANSI"
```

---

### Task 2: `CopiarTexto.swift` — o vocabulário de copiar

**Arquivos:**
- Criar: `app/CutuqueApp/CopiarTexto.swift`
- Teste: `app/CutuqueAppTests/CopiarTextoTests.swift` (criar)

**Interfaces:**
- Consome: nada além de SwiftUI/UIKit.
- Produz (tasks 3, 4 e 5 dependem destes nomes exatos):
  - `AreaDeTransferencia.copiar(_ texto: String)`
  - `TextoParaCopiar.aparado(_ texto: String) -> String`
  - `TextoParaCopiar.doTerminal(selecionado: String?, tela: String) -> String`
  - `TextoParaCopiar.deFerramenta(comando: String, resultado: String?) -> String`
  - `FolhaDeTexto(titulo: String, texto: String, monoespacado: Bool = false)`
  - `BotaoDeCopiar(texto: String, rotulo: String? = nil)`

- [ ] **Passo 1: escrever o teste que falha**

```swift
import XCTest
@testable import CutuqueApp

/// As regras puras de "o que exatamente vai pra área de transferência". Ficam
/// fora das Views (padrão da casa) porque é aqui que mora o que faz o texto ser
/// COLÁVEL — e um erro aqui a usuária só descobre no WhatsApp.
final class CopiarTextoTests: XCTestCase {

    // MARK: aparado

    func testAparaEspacoADireitaDeCadaLinha() {
        // A tela de um terminal é uma matriz 80x24 preenchida de espaço. Sem
        // aparar, cada linha colada leva uma cauda de espaços invisíveis.
        XCTAssertEqual(TextoParaCopiar.aparado("olá   \nmundo\t\n"), "olá\nmundo")
    }

    func testAparaLinhasVaziasDoFim() {
        XCTAssertEqual(TextoParaCopiar.aparado("conteúdo\n\n   \n\n"), "conteúdo")
    }

    func testPreservaLinhaVaziaNoMeio() {
        // Parágrafo é informação: aparar o meio destruiria a saída de um
        // comando que separa blocos por linha em branco.
        XCTAssertEqual(TextoParaCopiar.aparado("a\n\nb"), "a\n\nb")
    }

    func testTextoSoDeEspacoViraVazio() {
        // É o que permite desabilitar o botão em terminal ainda conectando,
        // em vez de copiar 24 linhas de nada.
        XCTAssertEqual(TextoParaCopiar.aparado("   \n\t\n  "), "")
        XCTAssertEqual(TextoParaCopiar.aparado(""), "")
    }

    func testNaoAparaEspacoADireitaDeLinhaDoMeioQueEIndentacao() {
        // Indentação (espaço à ESQUERDA) é conteúdo — código colado sem ela
        // não roda. Só a cauda some.
        XCTAssertEqual(TextoParaCopiar.aparado("def f():\n    return 1   \n"),
                       "def f():\n    return 1")
    }

    // MARK: doTerminal

    func testSelecaoDaUsuariaGanhaDaTela() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "só isto", tela: "a tela toda"),
                       "só isto")
    }

    func testSemSelecaoCaiNaTela() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: nil, tela: "a tela toda"),
                       "a tela toda")
    }

    func testSelecaoVaziaOuSoEspacoCaiNaTela() {
        // O SwiftTerm devolve string vazia quando a seleção existe mas não
        // cobre nada; cair na tela é melhor que copiar vazio.
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "", tela: "tela"), "tela")
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "   \n ", tela: "tela"), "tela")
    }

    func testOsDoisLadosSaemAparados() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "sel   \n\n", tela: "x"), "sel")
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: nil, tela: "tela  \n\n\n"), "tela")
    }

    // MARK: deFerramenta

    func testComandoComResultado() {
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: "total 0"),
                       "$ ls -la\ntotal 0")
    }

    func testComandoAindaSemResultado() {
        // Tool call em voo: o resultado ainda não chegou. Copiar só o comando é
        // o certo — não uma linha vazia pendurada.
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: nil),
                       "$ ls -la")
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: "   "),
                       "$ ls -la")
    }

    func testResultadoMultilinhaMantemAsLinhas() {
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "git status", resultado: "a\nb\n"),
                       "$ git status\na\nb")
    }
}
```

- [ ] **Passo 2: rodar e VER falhar**

Esperado: "cannot find 'TextoParaCopiar' in scope".

- [ ] **Passo 3: implementar o mínimo**

Criar `app/CutuqueApp/CopiarTexto.swift`:

```swift
import SwiftUI
import UIKit

/// Copiar conteúdo para FORA do app — a usuária lendo o Cutuque no iPad sem
/// computador perto e querendo colar no WhatsApp.
///
/// O desenho não briga com nenhuma das três superfícies (chat picado em vários
/// `Text`, espelho tmux que republica a cada quadro, SwiftTerm com gesto comido
/// pelo mouse-reporting). Em vez disso: um toque copia a coisa inteira, e quem
/// quer um trecho abre `FolhaDeTexto`, um retrato IMÓVEL onde a seleção nativa
/// do iOS funciona porque nada muda embaixo dela.
/// Ver docs/superpowers/specs/2026-08-12-copiar-conteudo-design.md.
enum AreaDeTransferencia {
    static func copiar(_ texto: String) {
        UIPasteboard.general.string = texto
    }
}

/// O que EXATAMENTE vai para a área de transferência. Puro de propósito (padrão
/// da casa: decisão fora da View) — é aqui que mora o que faz o texto ser
/// colável, e um erro aqui só apareceria no WhatsApp.
enum TextoParaCopiar {

    /// Apara a cauda de espaço de cada linha e as linhas vazias do fim.
    ///
    /// Não é cosmético: a tela de um terminal é uma matriz 80x24 preenchida de
    /// espaço, então copiar cru cola um bloco com cauda invisível em toda linha
    /// e um punhado de linhas vazias no fim. Linha vazia no MEIO fica: parágrafo
    /// é informação. Espaço à ESQUERDA fica: indentação é conteúdo.
    static func aparado(_ texto: String) -> String {
        var linhas = texto.components(separatedBy: "\n").map { linha in
            String(linha.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        while let ultima = linhas.last, ultima.isEmpty { linhas.removeLast() }
        return linhas.joined(separator: "\n")
    }

    /// A seleção da usuária quando ela conseguiu fazer uma; senão a tela toda.
    ///
    /// Existe porque no terminal ssh (SwiftTerm) às vezes a seleção nativa
    /// funciona — quando funciona, respeitar é melhor que ignorar. Vazio ou só
    /// espaço conta como "não selecionou".
    static func doTerminal(selecionado: String?, tela: String) -> String {
        if let selecionado {
            let limpo = aparado(selecionado)
            if !limpo.isEmpty { return limpo }
        }
        return aparado(tela)
    }

    /// Uma tool call como a usuária leria num terminal: o comando com `$` na
    /// frente e, embaixo, a saída. O que ela quer mandar não é "o comando" nem
    /// "o resultado" — é o par.
    ///
    /// Toma `String` em vez de `ChatItem` porque `ChatItem` é `private` dentro
    /// de `SessionDetailView.swift`; a regra sobre String é testável sem expor
    /// o tipo privado.
    static func deFerramenta(comando: String, resultado: String?) -> String {
        let cabeca = "$ " + aparado(comando)
        guard let resultado else { return cabeca }
        let corpo = aparado(resultado)
        return corpo.isEmpty ? cabeca : cabeca + "\n" + corpo
    }
}

/// Um retrato IMÓVEL do texto, onde a seleção nativa do iOS funciona.
///
/// A imobilidade é o mecanismo, não um detalhe: `texto` é uma `String` já
/// copiada no instante do toque, então nem o `@Published` do espelho tmux nem o
/// fluxo de bytes do ssh mexem nela enquanto a usuária arrasta as alças. Um
/// `Text` só, também de propósito: `.textSelection` não atravessa a fronteira
/// entre dois `Text` — é justamente por isso que a seleção não funciona no chat.
struct FolhaDeTexto: View {
    let titulo: String
    let texto: String
    var monoespacado: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Só vertical: com rolagem horizontal ligada, o `maxWidth: .infinity`
            // de baixo brigaria com a largura infinita do ScrollView. Linha
            // comprida de terminal quebra na tela — e não faz diferença nenhuma
            // pro que é copiado, que é a String, não o layout.
            ScrollView(.vertical) {
                Text(texto)
                    .font(monoespacado ? .system(.footnote, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BotaoDeCopiar(texto: texto, rotulo: "Copiar tudo")
                }
            }
        }
    }
}

/// Copia e diz que copiou. O retorno visual não é enfeite: sem ele a usuária
/// não tem como saber se pegou, toca de novo e fica na dúvida se colou o certo.
struct BotaoDeCopiar: View {
    let texto: String
    var rotulo: String? = nil

    @State private var copiado = false

    var body: some View {
        Button {
            AreaDeTransferencia.copiar(texto)
            copiado = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                copiado = false
            }
        } label: {
            // `if/else` e não um `.labelStyle(cond ? .iconOnly : .titleAndIcon)`:
            // os dois estilos são TIPOS concretos diferentes e o ternário não
            // tipa. `@ViewBuilder` resolve sem ginástica.
            if let rotulo {
                Label(rotulo, systemImage: copiado ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copiado ? "checkmark" : "doc.on.doc")
            }
        }
        .disabled(TextoParaCopiar.aparado(texto).isEmpty)
        .accessibilityLabel(copiado ? "Copiado" : (rotulo ?? "Copiar"))
    }
}
```

- [ ] **Passo 4: rodar e ver passar**

Regenere os dois projetos (dois arquivos novos!). Esperado: 392 + 12 = **404
testes, 0 falhas**, confirmado no `xcresulttool`.

- [ ] **Passo 5: commit**

```bash
git add app/CutuqueApp/CopiarTexto.swift app/CutuqueAppTests/CopiarTextoTests.swift
git commit -m "feat(copiar): folha congelada, botao de copiar e as regras puras do que vai pro clipboard"
```

---

### Task 3: Chat — menu de contexto no funil e botão no bloco de código

**Arquivos:**
- Modificar: `app/CutuqueApp/SessionDetailView.swift` (`chatItemView`, ~linha 918)
- Modificar: `app/CutuqueApp/MarkdownText.swift` (`codeCard`, linhas 73-95)
- Teste: nenhum arquivo novo. **Isto é intencional e não é lacuna:** toda a
  regra pura desta superfície (`deFerramenta`, `aparado`) já está testada na
  Task 2. O que sobra aqui é fiação de View, que só se verifica no simulador.
  A obrigação desta task é **não deixar a suíte cair de 404**.

**Interfaces:**
- Consome: `AreaDeTransferencia.copiar`, `TextoParaCopiar.deFerramenta`,
  `FolhaDeTexto`, `BotaoDeCopiar` (Task 2).
- Produz: nada para outras tasks.

- [ ] **Passo 1: botão de copiar no cabeçalho do bloco de código**

Em `MarkdownText.swift`, trocar o `if !lang.isEmpty || isDiff { … }` das linhas
77-82 por uma barra que existe SEMPRE que há bloco de código:

```swift
            // [12/08/2026] A barra passa a existir sempre que há bloco de
            // código; o que é opcional é o RÓTULO da linguagem. Antes a barra
            // inteira dependia de `lang` estar preenchido, e era justamente o
            // bloco cercado sem linguagem — o mais comum na saída do agente —
            // que ficava sem lugar para o botão de copiar.
            HStack(spacing: 6) {
                if !lang.isEmpty || isDiff {
                    Text(isDiff ? "diff" : lang.lowercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                BotaoDeCopiar(texto: code)
                    .font(.caption)
            }
            .padding(.horizontal, 10).padding(.top, 6)
```

`code` é o texto CRU do bloco — o que a usuária quer colar, não o renderizado.

- [ ] **Passo 2: menu de contexto no funil do chat**

Em `SessionDetailView.swift`, `chatItemView` é o **único** ponto por onde passam
os três tipos de item. Envolver o `switch` num `Group` e pendurar o
`.contextMenu` nele:

```swift
    @ViewBuilder
    private func chatItemView(_ item: ChatItem) -> some View {
        // O menu vai NO FUNIL, não nas três folhas: bolha da usuária, resposta
        // do agente e tool call ganham copiar de uma vez, e o texto que ele
        // copia é o CRU de `ChatItem.content` — não o markdown renderizado, que
        // é justamente o que a seleção nativa não consegue atravessar
        // (MarkdownText faz um `Text` por bloco).
        Group {
            switch item.content {
            case .user(let text):      userBubble(text)
            case .assistant(let text): assistantBlock(text)
            case .tool(let command, let result): ToolGroupView(command: command, result: result)
            }
        }
        .contextMenu {
            Button {
                AreaDeTransferencia.copiar(textoCruDoItem(item))
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            Button {
                folhaDeTexto = FolhaPedida(titulo: tituloDaFolha(item),
                                           texto: textoCruDoItem(item),
                                           monoespacado: ehFerramenta(item))
            } label: {
                Label("Selecionar texto…", systemImage: "selection.pin.in.out")
            }
        }
    }

    /// Único lugar que traduz `ChatItem.Content` no texto que sai do app.
    private func textoCruDoItem(_ item: ChatItem) -> String {
        switch item.content {
        case .user(let t):        return TextoParaCopiar.aparado(t)
        case .assistant(let t):   return TextoParaCopiar.aparado(t)
        case .tool(let c, let r): return TextoParaCopiar.deFerramenta(comando: c, resultado: r)
        }
    }

    private func ehFerramenta(_ item: ChatItem) -> Bool {
        if case .tool = item.content { return true }
        return false
    }

    private func tituloDaFolha(_ item: ChatItem) -> String {
        switch item.content {
        case .user:      return "Sua mensagem"
        case .assistant: return "Resposta do agente"
        case .tool:      return "Comando e saída"
        }
    }
```

- [ ] **Passo 3: o estado e a folha**

Acrescentar o `@State` junto dos outros `@State` de `SessionDetailView` e o
`.sheet` junto dos `.sheet` que já existem no `body` (procure por `.sheet(` no
arquivo e ponha o novo logo depois do último):

```swift
    /// A folha de seleção pedida por um item do chat. `Identifiable` com `id`
    /// próprio (e não `String?`) porque pedir DUAS vezes o mesmo texto tem de
    /// reabrir a folha.
    private struct FolhaPedida: Identifiable {
        let id = UUID()
        let titulo: String
        let texto: String
        let monoespacado: Bool
    }

    @State private var folhaDeTexto: FolhaPedida?
```

```swift
        .sheet(item: $folhaDeTexto) { pedida in
            FolhaDeTexto(titulo: pedida.titulo, texto: pedida.texto,
                         monoespacado: pedida.monoespacado)
        }
```

Se `chatItemView` e o `body` estiverem em **tipos diferentes** dentro do arquivo,
o `@State` e o `.sheet` vão no tipo que hospeda `chatItemView` — o `.sheet` pode
ser pendurado no próprio `Group` de `chatItemView` como último recurso. Confira
antes de escrever; não presuma.

- [ ] **Passo 4: rodar a suíte**

Nenhum arquivo novo ⇒ não precisa regenerar os projetos. Esperado: **404 testes,
0 falhas** — igual à Task 2. Qualquer número diferente é regressão desta task.

- [ ] **Passo 5: commit**

```bash
git add app/CutuqueApp/SessionDetailView.swift app/CutuqueApp/MarkdownText.swift
git commit -m "feat(copiar): chat — copiar item inteiro pelo funil e bloco de codigo em um toque"
```

---

### Task 4: Espelho tmux ao vivo — menu de copiar na toolbar

**Arquivos:**
- Modificar: `app/CutuqueApp/TerminalMirrorView.swift` (toolbar ~linha 317, `themeMenu` ~368)
- Teste: nenhum novo — mesma justificativa da Task 3 (`Ansi.plain` e `aparado`
  já testados nas tasks 1 e 2). Obrigação: não deixar a suíte cair de 404.

**Interfaces:**
- Consome: `Ansi.plain` (Task 1); `AreaDeTransferencia.copiar`,
  `TextoParaCopiar.aparado`, `FolhaDeTexto`, `BotaoDeCopiar` (Task 2).
- Produz: nada.

- [ ] **Passo 1: o retrato do instante**

Acrescentar, junto das outras propriedades computadas da view:

```swift
    /// A tela do espelho como texto colável, NO INSTANTE da leitura.
    ///
    /// É por isso que copiar funciona aqui: `model.screen` é `@Published` e
    /// chega do WebSocket a cada atualização de tela, então a seleção nativa
    /// morre a cada quadro (e o auto-scroll animado do `.onChange` interrompe o
    /// gesto). Uma `String` copiada agora não muda mais, aconteça o que
    /// acontecer atrás dela.
    private var telaColavel: String {
        TextoParaCopiar.aparado(Ansi.plain(model.screen))
    }
```

- [ ] **Passo 2: o menu, num item próprio da toolbar**

O `themeMenu` tem ícone de paleta; copiar não mora lá. Acrescentar um
`ToolbarItem` novo logo depois do `ToolbarItem(placement: .topBarTrailing) { themeMenu }`
(linha ~317):

```swift
                ToolbarItem(placement: .topBarTrailing) { menuDeCopiar }
```

E o menu, junto do `themeMenu` na seção `// MARK: Toolbar`:

```swift
    private var menuDeCopiar: some View {
        Menu {
            Button {
                AreaDeTransferencia.copiar(telaColavel)
            } label: {
                Label("Copiar tela", systemImage: "doc.on.doc")
            }
            Button {
                folhaDaTela = TextoIdentificavel(telaColavel)
            } label: {
                Label("Selecionar texto…", systemImage: "selection.pin.in.out")
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .disabled(telaColavel.isEmpty)
        .accessibilityLabel("Copiar conteúdo da tela")
    }
```

- [ ] **Passo 3: o estado e a folha**

O `@State` guarda **já** o embrulho identificável, não a `String`:

```swift
    /// Retrato congelado pedido pela usuária.
    ///
    /// Guarda o embrulho, e NÃO uma `String?` mapeada no `body`: `.map` no
    /// binding criaria um `id` novo a cada avaliação do `body` — e como o
    /// `model.screen` republica sem parar, o `.sheet(item:)` acharia que o item
    /// mudou a cada quadro e ficaria reapresentando a folha em laço.
    @State private var folhaDaTela: TextoIdentificavel?
```

E, junto dos outros modificadores do `body` (perto dos `.alert` das linhas
349-363):

```swift
        .sheet(item: $folhaDaTela) { pedida in
            FolhaDeTexto(titulo: "Tela do terminal", texto: pedida.texto, monoespacado: true)
        }
```

O `Button` do Passo 2 então faz `folhaDaTela = TextoIdentificavel(telaColavel)`.
O embrulho vai no fim deste arquivo:

```swift
/// Embrulho para `.sheet(item:)` com um texto solto. Existe porque `String` não
/// é `Identifiable` e porque o que a folha precisa é o RETRATO, não o binding.
private struct TextoIdentificavel: Identifiable {
    let id = UUID()
    let texto: String
    init(_ texto: String) { self.texto = texto }
}
```

- [ ] **Passo 4: rodar a suíte**

Nenhum arquivo novo ⇒ sem regenerar. Esperado: **404 testes, 0 falhas**.

- [ ] **Passo 5: commit**

```bash
git add app/CutuqueApp/TerminalMirrorView.swift
git commit -m "feat(copiar): espelho tmux — copiar a tela e folha congelada pra selecionar"
```

---

### Task 5: Terminal ssh (SwiftTerm) — ponte de leitura e menu de copiar

**Arquivos:**
- Modificar: `app/CutuqueApp/PTYTerminalView.swift` (`makeUIView` ~34, `dismantleUIView` ~82)
- Modificar: `app/CutuqueApp/MachineDetailView.swift` (`body`/toolbar 74-100, `terminalPane` ~173)
- Teste: `app/CutuqueAppTests/JanelaVisivelTests.swift` (criar)

**Interfaces:**
- Consome: `AreaDeTransferencia.copiar`, `TextoParaCopiar.doTerminal`,
  `FolhaDeTexto` (Task 2).
- Produz: `TerminalTexto` (classe-ponte) e `JanelaVisivel` — só usados aqui.

**APIs do SwiftTerm — todas públicas, conferidas na fonte do pacote. Não
improvise outras:**

| Preciso de | API |
|---|---|
| o terminal | `TerminalView.getTerminal() -> Terminal` (`Apple/AppleTerminalView.swift:345`) |
| seleção ativa? | `TerminalView.selection.active` (`iOS/iOSTerminalView.swift:238`, `SelectionService.swift:132`) |
| texto selecionado | `TerminalView.selection.getSelectedText()` (`SelectionService.swift:669`) |
| 1ª linha visível | `terminal.buffer.yDisp` (`Buffer.swift:58`) |
| tamanho da tela | `terminal.rows`, `terminal.cols` (`Terminal.swift:326,329`) |
| texto de um trecho | `terminal.getText(start: Position, end: Position)` (`Terminal.swift:7112`) |

Dois detalhes que **não** são óbvios e você não deve reinventar:

1. `Buffer.lines` é **internal** — não dá para ler o total de linhas do app. Não
   precisa: `getSelectedLines` (`Terminal.swift:7789-7794`) já apara `end.row`
   ao tamanho do buffer e devolve `[]` se `start.row` passar do fim.
2. `endCol` do `translateToString` é **exclusivo** (`BufferLine.swift:502-511`:
   `for i in startCol..<limit`) e ele já faz `trimRight`. Portanto a coluna final
   é `cols`, **não** `cols - 1`. O próprio `selectAll` do SwiftTerm usa `cols-1`
   e por isso perde o último caractere de uma linha cheia — não copie esse erro.

- [ ] **Passo 1: escrever o teste que falha**

Criar `app/CutuqueAppTests/JanelaVisivelTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

/// A aritmética de "quais linhas do buffer estão na tela". Sozinha ela é trivial
/// — e é exatamente por isso que o erro de 1 passa batido: com `base` errado
/// some a última linha da tela (a que a usuária mais quer copiar, onde está o
/// resultado do comando que ela acabou de rodar).
final class JanelaVisivelTests: XCTestCase {

    func testTelaNoTopoDoBuffer() {
        let j = JanelaVisivel.linhas(yDisp: 0, rows: 24)
        XCTAssertEqual(j?.topo, 0)
        XCTAssertEqual(j?.base, 23, "24 linhas visíveis são 0...23, não 0...24")
    }

    func testTelaRoladaSomaODeslocamento() {
        let j = JanelaVisivel.linhas(yDisp: 100, rows: 24)
        XCTAssertEqual(j?.topo, 100)
        XCTAssertEqual(j?.base, 123)
    }

    func testTelaDeUmaLinhaSoTemTopoIgualABase() {
        let j = JanelaVisivel.linhas(yDisp: 7, rows: 1)
        XCTAssertEqual(j?.topo, 7)
        XCTAssertEqual(j?.base, 7)
    }

    func testTerminalSemAlturaNaoTemJanela() {
        // Acontece de verdade: o emulador nasce com frame .zero antes do
        // primeiro layout. Devolver uma janela inválida aqui viraria um
        // getText com end antes do start.
        XCTAssertNil(JanelaVisivel.linhas(yDisp: 0, rows: 0))
        XCTAssertNil(JanelaVisivel.linhas(yDisp: 5, rows: -1))
    }
}
```

- [ ] **Passo 2: rodar e VER falhar**

Esperado: "cannot find 'JanelaVisivel' in scope".

- [ ] **Passo 3: a ponte e a aritmética**

No fim de `PTYTerminalView.swift`, fora da struct:

```swift
/// Quais linhas do buffer estão na tela. Separada da ponte porque é a única
/// parte disto que se testa sem um `TerminalView` de verdade — e é onde o erro
/// de 1 mora. Sem clamp de propósito: quem apara `base` ao tamanho real do
/// buffer é o `Terminal.getSelectedLines` do SwiftTerm, e `Buffer.lines` é
/// internal (o app não tem como contar as linhas).
enum JanelaVisivel {
    static func linhas(yDisp: Int, rows: Int) -> (topo: Int, base: Int)? {
        guard rows > 0 else { return nil }
        return (topo: yDisp, base: yDisp + rows - 1)
    }
}

/// Deixa o SwiftUI LER o terminal sem virar dono dele.
///
/// Existe porque no iOS o caminho de copiar do próprio SwiftTerm não chega na
/// usuária: `allowMouseReporting` nasce `true` e os guardas de mouse-reporting
/// desviam o gesto para o programa que roda dentro (`iOSTerminalView.swift:800,
/// 851, 876, 972`), e o menu usa `UIMenuController`, depreciado desde o iOS 16
/// (`iOSTerminalView.swift:629`). Em vez de mexer nesses dois — mouse dentro do
/// ssh é útil, e brigar com o menu do sistema é areia demais — o app lê o texto
/// por fora e oferece copiar na SUA toolbar.
///
/// `weak` não é detalhe: a ponte não pode manter o `TerminalView` vivo depois do
/// `dismantleUIView`. Com a aba montada para sempre (decisão #19), uma
/// referência forte aqui seria vazamento por aba aberta.
@MainActor
final class TerminalTexto {
    weak var view: TerminalView?

    /// A tela visível como texto. Só a tela — sem scrollback, por decisão da
    /// usuária (não mexe no hub).
    func telaVisivel() -> String {
        guard let view else { return "" }
        let terminal = view.getTerminal()
        guard let janela = JanelaVisivel.linhas(yDisp: terminal.buffer.yDisp,
                                               rows: terminal.rows) else { return "" }
        // `cols` e não `cols - 1`: o endCol do SwiftTerm é EXCLUSIVO e já apara
        // à direita (BufferLine.swift:502-511). Com `cols - 1` a última coluna
        // de uma linha cheia sumiria — é o erro que o `selectAll` da própria
        // lib comete.
        return terminal.getText(start: Position(col: 0, row: janela.topo),
                                end: Position(col: terminal.cols, row: janela.base))
    }

    /// O que a usuária selecionou dentro do SwiftTerm, quando ela conseguiu.
    /// Às vezes o gesto passa; quando passa, respeitar é melhor que ignorar.
    func selecionado() -> String? {
        guard let view, view.selection.active else { return nil }
        let texto = view.selection.getSelectedText()
        return texto.isEmpty ? nil : texto
    }
}
```

Em `PTYTerminalView`, uma propriedade nova e dois fios:

```swift
    /// Ponte de leitura para a toolbar copiar o que está na tela. Opcional
    /// porque quem só desenha o terminal não precisa dela.
    var texto: TerminalTexto? = nil
```

No fim de `makeUIView`, antes do `return view`:

```swift
        texto?.view = view
```

Em `dismantleUIView`, junto do corte do cano:

```swift
        // A ponte é `weak`, mas zerar aqui é explícito: ninguém lê uma view em
        // desmontagem.
        coordinator.texto?.view = nil
```

Para isso o `Coordinator` guarda a ponte (a struct é recriada a cada
atualização, o coordinator não — mesmo motivo do `temaAplicado`):

```swift
        @MainActor var texto: TerminalTexto?
```

e em `updateUIView`, junto das outras sincronizações:

```swift
        context.coordinator.texto = texto
```

- [ ] **Passo 4: o menu em `MachineDetailView`**

```swift
    /// Ponte de leitura do terminal. `@State` e não `@StateObject`: não é
    /// observável, é só um jeito de a toolbar alcançar o `TerminalView`.
    @State private var textoDoTerminal = TerminalTexto()

    @State private var folhaDoTerminal: TextoIdentificavelDaMaquina?
```

Passar a ponte em `terminalPane` (~linha 177), junto dos outros parâmetros de
`PTYTerminalView`:

```swift
                            texto: textoDoTerminal,
```

Acrescentar o item na toolbar, **só quando o painel do terminal está à frente**
(no painel de arquivos não há tela para copiar) — logo antes do
`ToolbarItem(placement: .navigationBarTrailing)` da paleta:

```swift
            ToolbarItem(placement: .navigationBarTrailing) {
                if showsTerminal {
                    Menu {
                        Button {
                            AreaDeTransferencia.copiar(textoParaCopiar())
                        } label: {
                            Label("Copiar tela", systemImage: "doc.on.doc")
                        }
                        Button {
                            folhaDoTerminal = TextoIdentificavelDaMaquina(textoParaCopiar())
                        } label: {
                            Label("Selecionar texto…", systemImage: "selection.pin.in.out")
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copiar conteúdo da tela")
                }
            }
```

```swift
    /// O retrato do que copiar, NO INSTANTE do toque: a seleção da usuária se
    /// ela conseguiu fazer uma, senão a tela visível.
    private func textoParaCopiar() -> String {
        TextoParaCopiar.doTerminal(selecionado: textoDoTerminal.selecionado(),
                                   tela: textoDoTerminal.telaVisivel())
    }
```

E a folha, junto do `.sheet(item: $sheetInfo)` que já existe (~linha 101):

```swift
        .sheet(item: $folhaDoTerminal) { pedida in
            FolhaDeTexto(titulo: "Tela de \(machine.name)", texto: pedida.texto,
                         monoespacado: true)
        }
```

com o embrulho no fim do arquivo (nome diferente do da Task 4 de propósito: as
duas tasks rodam em paralelo em arquivos diferentes e um nome igual em `private`
de arquivos distintos compila, mas ficaria confuso na leitura):

```swift
/// Embrulho para `.sheet(item:)` com um texto solto — `String` não é
/// `Identifiable`, e o que a folha precisa é o RETRATO, não o binding.
private struct TextoIdentificavelDaMaquina: Identifiable {
    let id = UUID()
    let texto: String
    init(_ texto: String) { self.texto = texto }
}
```

- [ ] **Passo 5: rodar e ver passar**

Arquivo de teste novo ⇒ regenerar os dois projetos. Esperado: 404 + 4 = **408
testes, 0 falhas**, confirmado no `xcresulttool`.

- [ ] **Passo 6: commit**

```bash
git add app/CutuqueApp/PTYTerminalView.swift app/CutuqueApp/MachineDetailView.swift \
        app/CutuqueAppTests/JanelaVisivelTests.swift
git commit -m "feat(copiar): terminal ssh — ponte de leitura da tela e menu de copiar"
```

---

## Verificação no dispositivo (fica com a mantenedora)

Nada disto é coberto por teste de unidade — é fiação de View e API do sistema:

1. **Chat, um toque:** bloco de código com linguagem e bloco cercado **sem**
   linguagem — os dois têm botão de copiar, e o que cai no clipboard é o código
   cru.
2. **Chat, toque longo:** na bolha da usuária, na resposta do agente e numa tool
   call. Em `Copiar`, colar no WhatsApp e conferir que veio inteiro. Em
   `Selecionar texto…`, arrastar as alças no meio do texto e usar o Copiar do
   sistema.
3. **Toque longo na tool call:** o comando está dentro de um `Button` — confirmar
   que o menu de contexto abre mesmo assim (se não abrir na área do botão, abre
   na área do resultado; anotar o comportamento).
4. **Espelho tmux VIVO** (com um comando cuspindo saída): `Copiar tela` durante o
   fluxo, e `Selecionar texto…` — a folha tem de ficar **imóvel** enquanto o
   terminal continua rolando atrás.
5. **Terminal ssh:** rodar `ls -la`, copiar a tela, colar fora. Repetir com
   `htop` aberto (tela alternativa). Depois tentar selecionar dentro do SwiftTerm
   e usar `Copiar tela` — tem de vir a seleção, não a tela.
6. **Terminal ssh recém-aberto**, antes do primeiro layout: o menu fica
   desabilitado/vazio em vez de copiar lixo.
7. **iPhone e iPad**, os dois — a spec é para os dois aparelhos.
