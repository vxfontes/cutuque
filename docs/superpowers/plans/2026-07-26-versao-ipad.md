# Versão iPad do Cutuque — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Levar o app Cutuque ao iPad como cidadão nativo — terminais tmux, chat e board — numa `NavigationSplitView` de três colunas, sem regredir nada no iPhone.

**Architecture:** O iPad ganha uma raiz nova (`RootSplitView`) escolhida **uma vez por idiom** no `CutuqueApp`; o iPhone continua no `RootTabView` de hoje, byte por byte. A split view é construída uma vez e nunca substituída — girar o aparelho muda só `columnVisibility`, que é estado, não estrutura. As views grandes que já existem (`SessionListView`, `SessionDetailView`, `TerminalMirrorView`, `BoardView`) são adaptadas para funcionar nos dois modos, e toda a lógica nova que dá para isolar (geometria do terminal, debounce, ritmo de poll, mapa de teclas, movimento otimista do board, navegação por teclado) sai como **função pura em arquivo próprio, coberta por teste**.

**Tech Stack:** Swift 5.9 · SwiftUI (iOS 17) · XcodeGen 2.45 · XCTest · `xcodebuild` / `xcrun simctl`

## Global Constraints

- Deployment target **iOS 17.0** (`app/project.yml:5`), watchOS 10.0. Nada de API acima disso; `.inspector`, `.onKeyPress` e `onChange(initial:)` são iOS 17 e estão liberados.
- `SWIFT_VERSION: "5.9"`.
- **Nenhuma dependência nova.** Sem SPM, sem pod, sem pacote.
- Todo texto de interface em **pt-BR**, minúsculo/natural no mesmo tom das strings existentes (ex.: "digitar no terminal…", "nada por aqui").
- **O iPhone não pode regredir.** Qualquer mudança em view compartilhada preserva o comportamento atual quando `UIDevice.current.userInterfaceIdiom != .pad`. Regressão no iPhone é motivo de rejeitar a task.
- `app/project.yml` é a fonte da verdade do projeto. **Depois de qualquer edição nele, rodar `xcodegen generate` dentro de `app/`** — nunca editar o `.xcodeproj` na mão.
- Comando de build padrão (usado em toda task):
  `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
  Esperado: exit 0. Existe **um** warning pré-existente em `PushManager.swift:65` (`timeSensitive` deprecado) — ele é esperado e não é sua responsabilidade.
- Comando de teste padrão (a partir da Task 2):
  `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
- Um commit por task, no fim. Branch: `versao-ipad`.

## Notas de precisão (leia antes de começar)

- O spec cita larguras exemplo ("detalhe de ~554 pt no 11\"", "~726 pt no 13\""). São **ilustrativas**. A implementação **mede** a largura real do painel de detalhe com `GeometryReader` e aplica a regra dos 700 pt sobre o valor medido. Não tente reproduzir os pt do spec.
- O spec diz "iPad 11\" abre expandido, 13\" abre em três colunas" — isso é a **consequência esperada** da regra, não uma condição a codificar por modelo de aparelho. Nunca ramifique por nome de aparelho.
- Onde o spec fala em `stop()` + `restoreSize()`, este plano resolve por tempo de vida da view (`ZStack` com opacidade em vez de troca de subview), não por flag. Ver Task 8.

---

## Estrutura de arquivos

**Novos em `app/CutuqueApp/`:**

| Arquivo | Responsabilidade |
|---|---|
| `TerminalGeometry.swift` | funções puras: colunas/linhas a partir de largura+fonte, fonte padrão por idiom, regra dos 700 pt |
| `TerminalTiming.swift` | `ResizeDebouncer` (janela de 300 ms) e `PollPacer` (1,5 s ↔ 3 s) |
| `TerminalKeyboard.swift` | mapa puro caractere+modificadores → nome de tecla do tmux |
| `NavigationState.swift` | estado de navegação do iPad: destino, seleção, modo do painel, visibilidade de colunas, intents de atalho |
| `RootSplitView.swift` | a `NavigationSplitView` de 3 colunas + `DestinationSidebar` |
| `SessionDetailPane.swift` | painel de detalhe da sessão: seletor Chat \| Terminal + botão ⤡ |
| `BoardFilterList.swift` | filtros e busca do board na coluna do meio |
| `BoardMoveLogic.swift` | funções puras: plano de movimento, aplicação otimista, navegação por teclado, largura de coluna |
| `CutuqueCommands.swift` | cena `Commands` com os atalhos ⌘ globais |

**Novo diretório `app/CutuqueAppTests/`** (alvo de teste unitário, não existe hoje).

**Modificados:**

| Arquivo | O quê |
|---|---|
| `app/project.yml` | `TARGETED_DEVICE_FAMILY: "1,2"` nos dois alvos; alvo de teste |
| `CutuqueApp.swift` | escolhe a raiz por idiom; cria `NavigationState` e `BoardModel` compartilhados; anexa `.commands` |
| `SessionListView.swift` | modo embutido (sem `NavigationStack` própria, linhas com `.tag`) |
| `SessionDetailView.swift` | consome o `⌘.` |
| `TerminalMirrorView.swift` | debounce, fonte por idiom, `isActive`, poll adaptativo, teclado físico |
| `BoardView.swift` | modelo injetado, colunas lado a lado, inspector, drag & drop otimista, teclado |

---

### Task 1: iPad como destino declarado + simuladores

O app hoje declara só iPhone. Esta task é a linha e meia que destrava tudo; nada de layout muda ainda.

**Files:**
- Modify: `app/project.yml:58` e `app/project.yml:108`

**Interfaces:**
- Consumes: nada.
- Produces: alvo `CutuqueApp` universal; simuladores `Cutuque iPad 11` e `Cutuque iPad 13` disponíveis para todas as tasks seguintes.

- [ ] **Step 1: Criar os dois simuladores de iPad**

Não existe nenhum aparelho de simulador criado hoje (`xcrun simctl list devices` volta vazio), embora os runtimes iOS 26.3 e watchOS 26.2 estejam instalados.

```bash
xcrun simctl create "Cutuque iPad 11" \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB \
  com.apple.CoreSimulator.SimRuntime.iOS-26-3
xcrun simctl create "Cutuque iPad 13" \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB \
  com.apple.CoreSimulator.SimRuntime.iOS-26-3
xcrun simctl create "Cutuque iPhone" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-3
```

Se `iPhone-16-Pro` não existir na sua máquina, escolha outro iPhone de `xcrun simctl list devicetypes | grep iPhone` — o nome do simulador (`Cutuque iPhone`) é o que importa.

- [ ] **Step 2: Verificar que os três aparecem**

Run: `xcrun simctl list devices available | grep Cutuque`
Expected: três linhas, `Cutuque iPad 11`, `Cutuque iPad 13`, `Cutuque iPhone`, todas `(Shutdown)`.

- [ ] **Step 3: Declarar a família universal nos dois alvos**

Em `app/project.yml:58` (alvo `CutuqueApp`) e `app/project.yml:108` (alvo `CutuqueWidgets`), trocar:

```yaml
        TARGETED_DEVICE_FAMILY: "1"
```

por:

```yaml
        # "1,2" = iPhone + iPad. O widget acompanha o app: uma Live Activity de
        # extension declarada só como iPhone não aparece no iPad.
        TARGETED_DEVICE_FAMILY: "1,2"
```

São **duas** ocorrências. Trocar as duas.

- [ ] **Step 4: Regerar e compilar**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0, apenas o warning conhecido de `PushManager.swift:65`.

- [ ] **Step 5: Rodar no iPad e conferir que abre nativo**

```bash
cd app
xcrun simctl boot "Cutuque iPad 13" || true
xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet
xcrun simctl install "Cutuque iPad 13" \
  "$(xcodebuild -project CutuqueApp.xcodeproj -scheme CutuqueApp -showBuildSettings -destination 'platform=iOS Simulator,name=Cutuque iPad 13' 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')"
xcrun simctl launch "Cutuque iPad 13" com.vxfontes.cutuque
open -a Simulator
```

Expected (verificação manual, olhe o simulador): o app abre **em tela cheia**, não numa janelinha de iPhone escalada com bordas pretas. O layout ainda é o de iPhone esticado (tab bar embaixo, listas largas) — isso é o esperado nesta fase.

- [ ] **Step 6: Commit**

```bash
git add app/project.yml app/CutuqueApp.xcodeproj
git commit -m "feat(ipad): declara TARGETED_DEVICE_FAMILY 1,2 no app e no widget"
```

---

### Task 2: Alvo de teste unitário

Não existe nenhum teste automatizado em `app/`. Todas as tasks de lógica pura deste plano dependem deste alvo existir.

**Files:**
- Modify: `app/project.yml` (bloco `targets`, depois do alvo `CutuqueApp`)
- Create: `app/CutuqueAppTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces: alvo `CutuqueAppTests`, ligado ao scheme `CutuqueApp`; `@testable import CutuqueApp` disponível para todas as tasks seguintes.

- [ ] **Step 1: Escrever o teste que ainda não tem onde rodar**

Create `app/CutuqueAppTests/SmokeTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

/// Prova que o alvo de teste existe, roda e enxerga o módulo do app.
final class SmokeTests: XCTestCase {
    func testColunasDoBoardEstaoNaOrdemDoFluxo() {
        XCTAssertEqual(
            BoardColumn.allCases.map(\.rawValue),
            ["a_fazer", "em_progresso", "feito", "em_revisao", "concluido"]
        )
    }
}
```

- [ ] **Step 2: Rodar e ver falhar por falta de alvo**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA — `Scheme CutuqueApp is not currently configured for the test action.`

- [ ] **Step 3: Declarar o alvo de teste**

Em `app/project.yml`, dentro do alvo `CutuqueApp`, **depois** do bloco `dependencies:` (hoje em `:60-63`), acrescentar:

```yaml
    # Liga o bundle de testes ao scheme do app, para `xcodebuild test` achar.
    scheme:
      testTargets:
        - CutuqueAppTests
```

E, no fim do arquivo (depois do alvo `CutuqueWidgets`), acrescentar o alvo:

```yaml
  # Testes unitários da lógica pura do app (geometria do terminal, debounce,
  # movimento do board, mapa de teclas). Não há UI test — é decisão do spec.
  CutuqueAppTests:
    type: bundle.unit-test
    platform: iOS
    sources: [CutuqueAppTests]
    dependencies:
      - target: CutuqueApp
```

- [ ] **Step 4: Regerar e rodar o teste**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA — `Test Suite 'SmokeTests' passed`, 1 teste.

- [ ] **Step 5: Commit**

```bash
git add app/project.yml app/CutuqueAppTests app/CutuqueApp.xcodeproj
git commit -m "test: alvo CutuqueAppTests ligado ao scheme"
```

---

### Task 3: Geometria do terminal (função pura)

A conta de colunas/linhas hoje vive inline dentro do `GeometryReader` (`TerminalMirrorView.swift:196-200`). Extrair para poder testar e para a regra dos 700 pt ter onde morar.

**Files:**
- Create: `app/CutuqueApp/TerminalGeometry.swift`
- Test: `app/CutuqueAppTests/TerminalGeometryTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `TerminalGeometry.columns(width: CGFloat, fontPt: CGFloat) -> Int`
  - `TerminalGeometry.rows(height: CGFloat, fontPt: CGFloat) -> Int`
  - `TerminalGeometry.defaultFontPt(isPad: Bool) -> Double`
  - `TerminalGeometry.fontMin: Double` / `fontMax: Double`
  - `PadLayout.expandThreshold: CGFloat`
  - `PadLayout.startsExpanded(detailWidth: CGFloat) -> Bool`

- [ ] **Step 1: Escrever os testes que falham**

Create `app/CutuqueAppTests/TerminalGeometryTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

final class TerminalGeometryTests: XCTestCase {

    // Os números vêm da conta que já roda hoje na TerminalMirrorView:
    // cols = (largura - 16) / (fonte * 0.62)
    func testColunasNoIPhoneComFonteDeHoje() {
        // iPhone 15 Pro em retrato, 10 pt: (393-16)/6.2 = 60.8
        XCTAssertEqual(TerminalGeometry.columns(width: 393, fontPt: 10), 60)
    }

    func testColunasNoIPadExpandidoComFonteDoIPad() {
        // 11" expandido, 13 pt: (1194-16)/8.06 = 146.1
        XCTAssertEqual(TerminalGeometry.columns(width: 1194, fontPt: 13), 146)
    }

    func testColunasNoIPadEmTresColunas() {
        // detalhe de 726 pt, 13 pt: (726-16)/8.06 = 88.0
        XCTAssertEqual(TerminalGeometry.columns(width: 726, fontPt: 13), 88)
    }

    func testColunasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.columns(width: 100, fontPt: 13), 30)
    }

    func testLinhasDescontamAsBarras() {
        // (834-120)/(13*1.28) = 42.9
        XCTAssertEqual(TerminalGeometry.rows(height: 834, fontPt: 13), 42)
    }

    func testLinhasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.rows(height: 130, fontPt: 13), 20)
    }

    func testFontePadraoMudaPorIdiom() {
        XCTAssertEqual(TerminalGeometry.defaultFontPt(isPad: false), 10)
        XCTAssertEqual(TerminalGeometry.defaultFontPt(isPad: true), 13)
    }

    func testRegraDos700Pt() {
        XCTAssertTrue(PadLayout.startsExpanded(detailWidth: 554))   // 11" em 3 colunas
        XCTAssertTrue(PadLayout.startsExpanded(detailWidth: 699))
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 700))  // limite é inclusivo pra cima
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 806))  // 13" em 3 colunas
    }

    func testLarguraZeroNaoDecideNada() {
        // Antes do primeiro layout a largura é 0; quem chama precisa ignorar,
        // mas a função não pode responder "expandido" por acidente.
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 0))
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA na compilação — `cannot find 'TerminalGeometry' in scope`.

- [ ] **Step 3: Escrever a implementação mínima**

Create `app/CutuqueApp/TerminalGeometry.swift`:

```swift
import CoreGraphics

/// Geometria do espelho de terminal. Só função pura — sem SwiftUI, sem rede —
/// para caber em teste. As constantes vêm da conta que já rodava inline na
/// `TerminalMirrorView`: 0.62 é a razão largura/altura do SF Mono com folga pra
/// a linha do claude não re-quebrar; 1.28 é a altura de linha; os 16/120 são o
/// padding horizontal e a altura das barras (teclas + input).
enum TerminalGeometry {
    static let charWidthRatio: CGFloat = 0.62
    static let lineHeightRatio: CGFloat = 1.28
    static let horizontalChrome: CGFloat = 16
    static let verticalChrome: CGFloat = 120

    static let minColumns = 30
    static let minRows = 20

    static let fontMin: Double = 5
    static let fontMax: Double = 22

    static func columns(width: CGFloat, fontPt: CGFloat) -> Int {
        max(minColumns, Int((width - horizontalChrome) / (fontPt * charWidthRatio)))
    }

    static func rows(height: CGFloat, fontPt: CGFloat) -> Int {
        max(minRows, Int((height - verticalChrome) / (fontPt * lineHeightRatio)))
    }

    /// 10 pt foi calibrado pros 393 pt do iPhone; num painel de detalhe de iPad
    /// isso vira letra miúda demais pra ler de braço estendido.
    static func defaultFontPt(isPad: Bool) -> Double { isPad ? 13 : 10 }
}

/// Regras de largura da versão iPad, comuns a board e terminal.
enum PadLayout {
    /// Abaixo disto o painel de detalhe é estreito demais pras duas superfícies
    /// largas: o board fica com coluna de ~110 pt e o terminal cai abaixo das
    /// 80 colunas clássicas. Nesses casos o destino abre já expandido.
    static let expandThreshold: CGFloat = 700

    static func startsExpanded(detailWidth: CGFloat) -> Bool {
        detailWidth > 0 && detailWidth < expandThreshold
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA, 9 testes de `TerminalGeometryTests` + o smoke.

- [ ] **Step 5: Commit**

```bash
git add app/CutuqueApp/TerminalGeometry.swift app/CutuqueAppTests/TerminalGeometryTests.swift app/CutuqueApp.xcodeproj
git commit -m "feat(terminal): extrai geometria e a regra dos 700 pt como função pura"
```

---

### Task 4: Debounce de resize e ritmo de poll (funções puras)

O risco de severidade **alta** do spec: `.task(id: "\(cols)x\(rows)")` em `TerminalMirrorView.swift:206` dispara `tmuxResize` a cada mudança de largura. No iPhone a largura nunca muda; no iPad ela muda na rotação, no ⤡ e — pior — dezenas de vezes durante o arraste do divisor do Split View.

**Files:**
- Create: `app/CutuqueApp/TerminalTiming.swift`
- Test: `app/CutuqueAppTests/TerminalTimingTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `ResizeDebouncer(delay: Duration)` — `@MainActor final class`
  - `ResizeDebouncer.schedule(cols: Int, rows: Int, send: @escaping @MainActor (Int, Int) -> Void)`
  - `ResizeDebouncer.cancel()`
  - `PollPacer` — `struct`, com `mutating func record(changed: Bool, elapsed: TimeInterval)` e `var interval: Duration`

- [ ] **Step 1: Escrever os testes que falham**

Create `app/CutuqueAppTests/TerminalTimingTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

@MainActor
final class ResizeDebouncerTests: XCTestCase {

    /// O caso que motiva tudo: arrastar o divisor gera uma rajada de tamanhos.
    /// Só o último pode virar POST.
    func testRajadaDeTamanhosViraUmUnicoResize() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var enviados: [(Int, Int)] = []

        for cols in 60...70 {
            debouncer.schedule(cols: cols, rows: 40) { c, r in enviados.append((c, r)) }
        }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(enviados.count, 1)
        XCTAssertEqual(enviados.first?.0, 70)
        XCTAssertEqual(enviados.first?.1, 40)
    }

    func testTamanhoRepetidoNaoReenvia() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var chamadas = 0

        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        try? await Task.sleep(for: .milliseconds(200))
        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(chamadas, 1)
    }

    func testTamanhosDiferentesEmMomentosDiferentesEnviamOsDois() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var enviados: [Int] = []

        debouncer.schedule(cols: 88, rows: 40) { c, _ in enviados.append(c) }
        try? await Task.sleep(for: .milliseconds(200))
        debouncer.schedule(cols: 146, rows: 40) { c, _ in enviados.append(c) }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(enviados, [88, 146])
    }

    func testCancelarImpedeOEnvioPendente() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(50))
        var chamadas = 0

        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        debouncer.cancel()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(chamadas, 0)
    }
}

final class PollPacerTests: XCTestCase {

    func testComecaRapido() {
        XCTAssertEqual(PollPacer().interval, .milliseconds(1500))
    }

    func testDesaceleraDepoisDe30sSemMudanca() {
        var pacer = PollPacer()
        for _ in 0..<19 { pacer.record(changed: false, elapsed: 1.5) }  // 28,5 s
        XCTAssertEqual(pacer.interval, .milliseconds(1500))
        pacer.record(changed: false, elapsed: 1.5)                       // 30,0 s
        XCTAssertEqual(pacer.interval, .seconds(3))
    }

    func testPrimeiroDiffVoltaAoRitmoRapido() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 60)
        XCTAssertEqual(pacer.interval, .seconds(3))
        pacer.record(changed: true, elapsed: 3)
        XCTAssertEqual(pacer.interval, .milliseconds(1500))
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA na compilação — `cannot find 'ResizeDebouncer' in scope`.

- [ ] **Step 3: Escrever a implementação mínima**

Create `app/CutuqueApp/TerminalTiming.swift`:

```swift
import Foundation

/// Segura a rajada de `tmuxResize` que o iPad provoca. A largura da view muda
/// na rotação, no botão de expandir e — pior — a cada frame do arraste do
/// divisor do Split View: sem isto, dezenas de POSTs seguidos pro hub.
///
/// Duas garantias: só o último tamanho da janela vira chamada, e um tamanho
/// igual ao último efetivamente enviado não vira chamada nenhuma.
@MainActor
final class ResizeDebouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var lastSent: (cols: Int, rows: Int)?

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    func schedule(cols: Int, rows: Int, send: @escaping @MainActor (Int, Int) -> Void) {
        if let last = lastSent, last.cols == cols, last.rows == rows { return }
        pending?.cancel()
        pending = Task { @MainActor [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.lastSent = (cols, rows)
            send(cols, rows)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Ritmo do polling do espelho. Uma captura de 220×60 é ~13 KB contra ~4 KB da
/// tela do iPhone: com a tela parada, 1,5 s é gasto de bateria e rede à toa.
struct PollPacer {
    static let fast: Duration = .milliseconds(1500)
    static let slow: Duration = .seconds(3)
    static let idleThreshold: TimeInterval = 30

    private(set) var quietFor: TimeInterval = 0

    mutating func record(changed: Bool, elapsed: TimeInterval) {
        quietFor = changed ? 0 : quietFor + elapsed
    }

    var interval: Duration { quietFor >= Self.idleThreshold ? Self.slow : Self.fast }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA, 7 testes novos.

- [ ] **Step 5: Commit**

```bash
git add app/CutuqueApp/TerminalTiming.swift app/CutuqueAppTests/TerminalTimingTests.swift app/CutuqueApp.xcodeproj
git commit -m "feat(terminal): debounce de resize e ritmo adaptativo de poll"
```

---

### Task 5: Estado de navegação do iPad

O cérebro da split view, isolado como classe simples para poder ser testado sem SwiftUI de verdade. Ainda não é usado por nenhuma view — é só a peça.

**Files:**
- Create: `app/CutuqueApp/NavigationState.swift`
- Test: `app/CutuqueAppTests/NavigationStateTests.swift`

**Interfaces:**
- Consumes: `Session` (`Models.swift:130`), `LiveEntry` (`SessionListView.swift:7`), `BoardTask` (`Models.swift:331`), `PadLayout` (Task 3).
- Produces:
  - `enum PadDestination: String, CaseIterable, Identifiable, Hashable` — `.sessions`, `.board`, `.archive`; `.label`, `.symbol`
  - `enum DetailSelection: Hashable` — `.session(Session)`, `.live(LiveEntry)`
  - `enum PaneMode: String` — `.chat`, `.terminal`
  - `enum AppIntent: Equatable` — `.reload`, `.newSession`, `.focusSearch`, `.interrupt`, `.selectSession(index: Int)`, `.moveCardLeft`, `.moveCardRight`
  - `@MainActor final class NavigationState: ObservableObject` com `destination`, `selection`, `paneMode`, `columnVisibility`, `archiveSelection`, `intent`, `wantsWidth`, `toggleColumns()`, `applyWidthRule(detailWidth:)`, `send(_:)`, `consume()`

- [ ] **Step 1: Tornar `LiveEntry` Hashable**

`DetailSelection` precisa ser `Hashable` para servir de seleção de `List` e de `.id()`. `DiscoveredSession` já é `Hashable` (`Models.swift:192`), então a conformidade é sintetizada.

Em `app/CutuqueApp/SessionListView.swift:7`, trocar:

```swift
struct LiveEntry: Identifiable, Equatable {
```

por:

```swift
struct LiveEntry: Identifiable, Equatable, Hashable {
```

- [ ] **Step 2: Escrever os testes que falham**

Create `app/CutuqueAppTests/NavigationStateTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import CutuqueApp

@MainActor
final class NavigationStateTests: XCTestCase {

    func testComecaNasSessoesComTresColunas() {
        let nav = NavigationState()
        XCTAssertEqual(nav.destination, .sessions)
        XCTAssertEqual(nav.columnVisibility, .all)
        XCTAssertEqual(nav.paneMode, .chat)
        XCTAssertNil(nav.selection)
    }

    func testChatNaoDisputaLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .chat
        XCTAssertFalse(nav.wantsWidth)
    }

    func testTerminalEBoardDisputamLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .terminal
        XCTAssertTrue(nav.wantsWidth)

        nav.destination = .board
        nav.paneMode = .chat
        XCTAssertTrue(nav.wantsWidth)
    }

    func testExpandirEhReversivel() {
        let nav = NavigationState()
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testRegraDe700AbreExpandidoNoDetalheEstreito() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyWidthRule(detailWidth: 554)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
    }

    func testRegraDe700MantemTresColunasNoDetalheLargo() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyWidthRule(detailWidth: 806)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testRegraDe700NaoExpandeODestinoQueNaoPedeLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .chat
        nav.applyWidthRule(detailWidth: 400)   // estreitíssimo, mas é chat
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testIntentEhConsumidoUmaVezSo() {
        let nav = NavigationState()
        nav.send(.reload)
        XCTAssertEqual(nav.intent, .reload)
        nav.consume()
        XCTAssertNil(nav.intent)
    }

    func testTodoDestinoTemRotuloESimbolo() {
        for d in PadDestination.allCases {
            XCTAssertFalse(d.label.isEmpty)
            XCTAssertFalse(d.symbol.isEmpty)
        }
    }
}
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA na compilação — `cannot find 'NavigationState' in scope`.

- [ ] **Step 4: Escrever a implementação mínima**

Create `app/CutuqueApp/NavigationState.swift`:

```swift
import SwiftUI

/// Destinos da sidebar do iPad que ocupam as colunas de conteúdo e detalhe.
/// Histórico, Hub e Ajustes também moram na sidebar, mas abrem em sheet — não
/// são destinos de coluna (ver `DestinationSidebar`).
enum PadDestination: String, CaseIterable, Identifiable, Hashable {
    case sessions, board, archive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessões"
        case .board:    return "Board"
        case .archive:  return "Arquivo"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .board:    return "rectangle.split.3x1"
        case .archive:  return "archivebox"
        }
    }
}

/// O que o painel de detalhe mostra quando o destino é Sessões. Uma sessão do
/// registry abre chat (+ terminal, se tiver pane); uma entrada ao vivo do tmux
/// só tem terminal.
enum DetailSelection: Hashable {
    case session(Session)
    case live(LiveEntry)
}

enum PaneMode: String, CaseIterable {
    case chat, terminal
}

/// Ações disparadas por atalho de teclado que precisam do contexto de uma view
/// (a lista de sessões, o board) para acontecer. Quem consome zera com
/// `consume()`.
enum AppIntent: Equatable {
    case reload
    case newSession
    case focusSearch
    case interrupt
    case selectSession(index: Int)
    case moveCardLeft
    case moveCardRight
}

/// Estado de navegação da versão iPad. Vive no `CutuqueApp` (para os atalhos
/// da cena `Commands` alcançarem) e desce por `environmentObject`.
///
/// Ele guarda **estado**, nunca estrutura: girar o iPad muda `columnVisibility`
/// e mais nada. É isso que impede a `NavigationSplitView` de ser remontada e,
/// com ela, o espelho do tmux de ser derrubado.
@MainActor
final class NavigationState: ObservableObject {
    @Published var destination: PadDestination = .sessions
    @Published var selection: DetailSelection?
    @Published var paneMode: PaneMode = .chat
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var archiveSelection: BoardTask?
    @Published var intent: AppIntent?

    /// O que está no detalhe agora disputa largura? Board sempre; sessão só
    /// quando está mostrando o terminal.
    var wantsWidth: Bool {
        destination == .board || (destination == .sessions && paneMode == .terminal)
    }

    func toggleColumns() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    /// Aplica a regra dos 700 pt. Chamada UMA vez por entrada em destino/painel
    /// (ver `RootSplitView`): depois disso a escolha do ⤡ é da usuária e vale
    /// até ela trocar de destino.
    func applyWidthRule(detailWidth: CGFloat) {
        columnVisibility = (wantsWidth && PadLayout.startsExpanded(detailWidth: detailWidth))
            ? .detailOnly
            : .all
    }

    func send(_ intent: AppIntent) { self.intent = intent }
    func consume() { intent = nil }
}
```

- [ ] **Step 5: Rodar e ver passar**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA, 9 testes novos.

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/NavigationState.swift app/CutuqueApp/SessionListView.swift app/CutuqueAppTests/NavigationStateTests.swift app/CutuqueApp.xcodeproj
git commit -m "feat(ipad): NavigationState com destino, seleção e regra dos 700 pt"
```

---

### Task 6: `SessionListView` em modo embutido

A lista precisa funcionar em dois modos: dona da própria `NavigationStack` (iPhone, como hoje) ou embutida na coluna `content` de uma split view, publicando a escolha por seleção de `List`.

**Files:**
- Modify: `app/CutuqueApp/SessionListView.swift` (`:257-281` propriedades, `:421-601` corpo, `:636-664` `liveRow`, `:683-712` `needsYouRow`, `:714-717` `sessionLink`)

**Interfaces:**
- Consumes: `DetailSelection` (Task 5).
- Produces: `SessionListView(splitSelection: Binding<DetailSelection?>?)` — `SessionListView()` continua compilando e se comportando exatamente como hoje.

- [ ] **Step 1: Acrescentar a propriedade de modo**

Em `SessionListView.swift`, logo depois de `@StateObject private var model = SessionListViewModel()` (`:258`), inserir:

```swift
    /// Quando não-nil, a lista roda embutida na coluna `content` de uma
    /// `NavigationSplitView` (iPad): não cria `NavigationStack` própria e
    /// publica a escolha aqui em vez de empurrar na pilha. Nil = iPhone, tudo
    /// exatamente como sempre foi.
    var splitSelection: Binding<DetailSelection?>?
    private var isEmbedded: Bool { splitSelection != nil }
```

`SessionListView` não tem `init` explícito, então o memberwise `SessionListView(splitSelection:)` aparece sozinho e `SessionListView()` continua válido.

- [ ] **Step 2: Reestruturar o corpo**

Trocar a abertura do corpo (`:421-423`):

```swift
    var body: some View {
        NavigationStack(path: $path) {
            List {
```

por:

```swift
    var body: some View {
        Group {
            if isEmbedded {
                listCore
            } else {
                NavigationStack(path: $path) {
                    listCore
                        // Destino único p/ NavigationLink e p/ push programático.
                        .navigationDestination(for: Session.self) { session in
                            SessionDetailView(session: session)
                        }
                }
            }
        }
        // A partir daqui vêm todos os `.sheet`, `.confirmationDialog`, `.alert`,
        // `.task` e `.onChange` que hoje estão dentro da NavigationStack — eles
        // valem nos dois modos e apresentam igual de fora dela.
        .sheet(isPresented: $showingNew) {
```

Ou seja: os modificadores de `:489` (`.sheet(isPresented: $showingNew)`) até `:599` (`.onChange(of: showingDiscover)`) **saem de dentro** da `NavigationStack` e passam a pendurar no `Group`. O que fica colado na lista é só `listCore`.

Depois disso, criar `listCore` com o miolo que estava em `:423-488`:

```swift
    /// A lista em si, com título e toolbar. Nos dois modos é a mesma coisa; o
    /// que muda é ter ou não uma NavigationStack em volta.
    @ViewBuilder private var listCore: some View {
        List(selection: splitSelection) {
            liveServerSections
            needsYouSection
            activeSection
            concludedSection
            subagentsSection
        }
        .listStyle(.insetGrouped)
        .overlay {
            if !model.didInitialLoad {
                ProgressView().controlSize(.large)
            } else if model.sessions.isEmpty && liveNotTracked.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Sessões")
        .toolbar {
            // …exatamente os quatro ToolbarItem de hoje (:444-487), sem mudança…
        }
    }
```

`List(selection:)` aceita um `Binding<SelectionValue?>?` **opcional**: passar `splitSelection` nil desliga a seleção e a lista se comporta como a `List { }` de hoje. O tipo `DetailSelection` é inferido do binding mesmo quando o valor é nil.

Remover a `.navigationDestination` de `:432-434` do miolo (ela subiu para o ramo não-embutido).

- [ ] **Step 3: Fazer as linhas responderem aos dois modos**

`sessionLink` (`:714-717`) vira:

```swift
    private func sessionLink(_ session: Session) -> some View {
        Group {
            if isEmbedded {
                SessionRow(session: session, title: namer.displayTitle(for: session))
                    .tag(DetailSelection.session(session))
            } else {
                NavigationLink(value: session) {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                }
            }
        }
        .contextMenu {
            // …o contextMenu de hoje (:718-...), sem mudança…
        }
    }
```

`liveRow` (`:636-664`): o corpo visual (`HStack` com `LivePulse`, título, pasta e o ícone de terminal) sai do `Button` para uma propriedade própria, e a linha vira:

```swift
    private func liveRow(_ entry: LiveEntry) -> some View {
        Group {
            if isEmbedded {
                liveRowLabel(entry)
                    .tag(DetailSelection.live(entry))
            } else {
                Button { selectedLive = entry } label: { liveRowLabel(entry) }
                    .buttonStyle(.plain)
            }
        }
    }

    /// O visual da linha ao vivo, sem o gesto — compartilhado pelos dois modos.
    private func liveRowLabel(_ entry: LiveEntry) -> some View {
        let color = liveColor(entry)
        return HStack(spacing: 12) {
            LivePulse(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.session.title)
                    .font(.body).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: machineSymbol(entry.machine))
                    Text(entry.session.folderName)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "terminal").foregroundStyle(color)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
```

`needsYouRow` (`:683-712`): o ramo com `tmuxTarget` também precisa das duas formas. Trocar o `Group { … }` interno (`:684-701`) por:

```swift
        Group {
            if let target = session.tmuxTarget {
                let entry = LiveEntry(
                    machine: session.machine,
                    session: DiscoveredSession(id: target, cwd: session.cwd ?? "",
                                               title: namer.displayTitle(for: session)))
                if isEmbedded {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                        .tag(DetailSelection.live(entry))
                } else {
                    Button { selectedLive = entry } label: {
                        SessionRow(session: session, title: namer.displayTitle(for: session))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if isEmbedded {
                SessionRow(session: session, title: namer.displayTitle(for: session))
                    .tag(DetailSelection.session(session))
            } else {
                NavigationLink(value: session) {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                }
            }
        }
        // …o .swipeActions de hoje (:703-711) continua igual, fora do Group…
```

- [ ] **Step 4: Ajustar o deep-link para o modo embutido**

`resolveDeepLink()` (`:606-623`) hoje só sabe empurrar na pilha e abrir sheet. Trocar o miolo do `if let session` por:

```swift
        if let session = model.sessions.first(where: { $0.id == id }) {
            let entry = session.tmuxTarget.map { target in
                LiveEntry(machine: session.machine,
                          session: DiscoveredSession(id: target, cwd: session.cwd ?? "",
                                                     title: namer.displayTitle(for: session)))
            }
            if let splitSelection {
                // iPad: o push vira seleção; o detalhe reage sozinho.
                splitSelection.wrappedValue = entry.map { .live($0) } ?? .session(session)
            } else if let entry {
                // Sessão do tmux: o push abre o TERMINAL AO VIVO, não o detalhe
                // (que fica vazio para sessões externas — bug antigo).
                selectedLive = entry
            } else if path.last?.id != session.id {
                path.append(session)
            }
            router.pendingSessionID = nil
        }
```

- [ ] **Step 5: Fazer criar/adotar sessão navegar nos dois modos**

Os callbacks das duas sheets fazem `path.append(session)` — no modo embutido `path` não é usado, então criar uma sessão no iPad não levaria a lugar nenhum. Acrescentar um helper junto de `resolveDeepLink()`:

```swift
    /// Navega pra uma sessão do jeito que o modo atual entende.
    private func go(to session: Session) {
        if let splitSelection {
            splitSelection.wrappedValue = .session(session)
        } else if path.last?.id != session.id {
            path.append(session)
        }
    }
```

e trocar `path.append(session)` por `go(to: session)` nos dois callbacks: `NewSessionView` (`:490-494`) e `DiscoverSessionsView` (`:496-...`, dentro do `if path.last?.id != session.id`, que o helper já cobre).

- [ ] **Step 6: Compilar e conferir que o iPhone continua igual**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

Depois, no simulador de iPhone (`Cutuque iPhone`, mesma sequência de install/launch do Task 1 Step 5), verificação manual:
- a aba Sessões abre a lista igual a antes;
- tocar numa sessão sem tmux **empurra** o chat;
- tocar numa linha "ao vivo" abre a sheet do `LiveDetailView`;
- voltar funciona;
- Nova tarefa, Histórico, Ajustes e Status do hub ainda abrem em sheet.

Nada aqui pode ter mudado — a lista ainda roda em modo não-embutido.

- [ ] **Step 7: Commit**

```bash
git add app/CutuqueApp/SessionListView.swift
git commit -m "feat(ipad): modo embutido na SessionListView (seleção em vez de push)"
```

---

### Task 7: `RootSplitView`, sidebar e troca de raiz por idiom

A peça central. A raiz do iPad é escolhida **uma vez**, por idiom — que nunca muda em tempo de execução — então a split view é construída uma vez e nunca substituída, que é a decisão #19.

**Files:**
- Create: `app/CutuqueApp/RootSplitView.swift`
- Modify: `app/CutuqueApp/CutuqueApp.swift:16-38`
- Modify: `app/CutuqueApp/BoardView.swift:88` (o modelo passa a vir do ambiente)

**Interfaces:**
- Consumes: `NavigationState`, `PadDestination`, `DetailSelection` (Task 5); `SessionListView(splitSelection:)` (Task 6); `BoardModel` (`BoardView.swift:9`).
- Produces:
  - `struct RootSplitView: View`
  - `struct DestinationSidebar: View` (interno ao arquivo)
  - `BoardModel` disponível via `@EnvironmentObject` em todo o app.

- [ ] **Step 1: Tirar o `BoardModel` de dentro da `BoardView`**

O board vai aparecer em duas colunas ao mesmo tempo (filtros no meio, kanban no detalhe) — as duas precisam do **mesmo** modelo. Em `BoardView.swift:88`, trocar:

```swift
    @StateObject private var model = BoardModel()
```

por:

```swift
    // Injetado pelo app: a coluna de filtros (iPad) precisa do MESMO modelo.
    @EnvironmentObject private var model: BoardModel
```

- [ ] **Step 2: Escrever a `RootSplitView`**

Create `app/CutuqueApp/RootSplitView.swift`:

```swift
import SwiftUI

/// Raiz do app no iPad: UMA `NavigationSplitView` de três colunas, construída
/// uma vez e nunca substituída.
///
/// Girar o aparelho não troca nada de estrutura — o próprio componente recolhe
/// a sidebar em retrato e a mostra em paisagem. É isso que preserva o espelho
/// do tmux vivo e a rolagem do chat na rotação (decisão #19). Trocar a raiz por
/// orientação faria o SwiftUI remontar a árvore, e o `onDisappear` do terminal
/// chama `stop()` e `restoreSize()` — girar derrubaria o pane no servidor.
struct RootSplitView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var nav: NavigationState

    /// Chave do que já teve a regra dos 700 pt aplicada, pra ela valer UMA vez
    /// por entrada em destino/painel e não brigar com o ⤡ da usuária.
    @State private var widthRuleAppliedFor: String?

    private var widthRuleKey: String { "\(nav.destination.rawValue)-\(nav.paneMode.rawValue)" }

    var body: some View {
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            DestinationSidebar()
        } content: {
            contentColumn
        } detail: {
            GeometryReader { geo in
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        guard width > 0, widthRuleAppliedFor != widthRuleKey else { return }
                        widthRuleAppliedFor = widthRuleKey
                        nav.applyWidthRule(detailWidth: width)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: widthRuleKey) { _, _ in widthRuleAppliedFor = nil }
        // Deep-link do push / Live Activity cai sempre em Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { nav.destination = .sessions }
        }
    }

    @ViewBuilder private var contentColumn: some View {
        switch nav.destination {
        case .sessions:
            SessionListView(splitSelection: $nav.selection)
        case .board:
            BoardFilterList()
        case .archive:
            ArchiveView(embedded: true, selection: $nav.archiveSelection)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch nav.destination {
        case .sessions:
            if let selection = nav.selection {
                // .id força a troca de sessão a destruir o painel anterior — é
                // aí, e só aí, que o `restoreSize()` do terminal deve rodar.
                SessionDetailPane(selection: selection).id(selection)
            } else {
                ContentUnavailableView("Escolha uma sessão", systemImage: "list.bullet.rectangle",
                                       description: Text("A conversa e o terminal aparecem aqui."))
            }
        case .board:
            BoardView()
        case .archive:
            if let task = nav.archiveSelection {
                ArchivedTaskPane(task: task)
            } else {
                ContentUnavailableView("Escolha um card", systemImage: "archivebox",
                                       description: Text("Os concluídos das semanas fechadas ficam aqui."))
            }
        }
    }
}

/// Sidebar. Sessões, Board e Arquivo são destinos de coluna; Histórico e
/// Ajustes continuam em sheet — são telas de consulta pontual, não valem uma
/// reescrita pra virar coluna.
///
/// O **status do hub** de propósito NÃO está aqui: a `HubStatusView` precisa
/// das sessões já carregadas (`sessions:`/`live:`) pro resumo, e a sidebar não
/// as tem. Ele fica onde sempre esteve, na toolbar da lista de sessões, com os
/// dados de verdade e o indicador colorido.
struct DestinationSidebar: View {
    @EnvironmentObject private var nav: NavigationState
    @State private var showingHistory = false
    @State private var showingSettings = false

    var body: some View {
        List(selection: $nav.destination) {
            Section {
                ForEach(PadDestination.allCases) { destination in
                    Label(destination.label, systemImage: destination.symbol)
                        .tag(destination)
                }
            }
            Section {
                Button { showingHistory = true } label: {
                    Label("Histórico", systemImage: "clock.arrow.circlepath")
                }
                Button { showingSettings = true } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Cutuque")
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .sheet(isPresented: $showingSettings) { HubSettingsView() }
    }
}

/// Card arquivado no painel de detalhe (só leitura).
struct ArchivedTaskPane: View {
    let task: BoardTask
    @StateObject private var readOnlyModel = BoardModel()

    var body: some View {
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true)
    }
}
```

`ArchiveView(embedded:selection:)`, `BoardFilterList` e `SessionDetailPane` ainda não existem — as próximas três tasks os criam. Para esta task compilar, crie **stubs mínimos** agora, no fim de `RootSplitView.swift`, e apague cada um na task que o implementa de verdade:

```swift
// MARK: - Stubs temporários (substituídos nas Tasks 8 e 13)

struct SessionDetailPane: View {
    let selection: DetailSelection
    var body: some View { Text("painel da sessão") }
}

struct BoardFilterList: View {
    var body: some View { Text("filtros") }
}
```

Para `ArchiveView`, em vez de stub, acrescentar os dois parâmetros já com default em `BoardView.swift:569-575`:

```swift
struct ArchiveView: View {
    var embedded: Bool = false
    var selection: Binding<BoardTask?>?
    @Environment(\.dismiss) private var dismiss
```

e, por ora, ignorá-los (a Task 13 os usa). Assim `ArchiveView()` continua funcionando no iPhone.

- [ ] **Step 3: Trocar a raiz por idiom no `CutuqueApp`**

Em `CutuqueApp.swift`, acrescentar às propriedades (depois de `:8`):

```swift
    // Estado de navegação do iPad. Mora aqui (e não na RootSplitView) porque a
    // cena `Commands` dos atalhos ⌘ precisa alcançá-lo.
    @StateObject private var nav = NavigationState()
    // Board compartilhado: no iPad a coluna de filtros e o kanban são views
    // diferentes olhando o mesmo modelo.
    @StateObject private var board = BoardModel()
```

E trocar o corpo da `WindowGroup` (`:17-34`) para:

```swift
        WindowGroup {
            // A raiz é escolhida por IDIOM, não por classe de tamanho. Idiom
            // nunca muda em tempo de execução: o `if` roda uma vez e a árvore
            // jamais é remontada. Classe de tamanho mudaria (iPhone Pro Max em
            // paisagem é `.regular`) e trocar a raiz derrubaria o espelho do
            // tmux — é exatamente o que a decisão #19 evita.
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    RootSplitView()
                } else {
                    RootTabView()
                }
            }
            .environmentObject(router)
            .environmentObject(nav)
            .environmentObject(board)
            .tint((AppAccent(rawValue: accentRaw) ?? .blue).color)
            .preferredColorScheme((AppColorScheme(rawValue: colorSchemeRaw) ?? .system).scheme)
            .onOpenURL { url in
                guard url.scheme == "cutuque", url.host == "session" else { return }
                let id = url.lastPathComponent
                if !id.isEmpty { router.openSession(id) }
            }
            .task {
                // Não bloquear a UI no launch: pede autorização após ~1s.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await PushManager.shared.requestAuthorization()
            }
        }
```

- [ ] **Step 4: Compilar**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 5: Critério de aceite da fase — girar não derruba nada**

Este é o teste que protege a decisão central. No simulador `Cutuque iPad 13`, com o hub alcançável:

1. Sidebar → **Sessões**. Escolher uma sessão de chat na coluna do meio. O chat aparece no detalhe.
2. Rolar o chat até o meio da conversa (não no fim).
3. **Girar para retrato** (`⌘←` no simulador) e **de volta para paisagem** (`⌘→`).
   Expected: a sidebar recolhe e volta; **a rolagem do chat continua onde estava**; nenhuma tela pisca em branco.
4. Escolher uma sessão **ao vivo do tmux** (linha com o ícone de terminal). O detalhe ainda é o stub "painel da sessão" — normal nesta task.
5. No iPhone (`Cutuque iPhone`): tudo exatamente como antes, tab bar embaixo, nada de sidebar.

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/RootSplitView.swift app/CutuqueApp/CutuqueApp.swift app/CutuqueApp/BoardView.swift
git commit -m "feat(ipad): RootSplitView de 3 colunas escolhida por idiom"
```

---

### Task 8: Painel de detalhe da sessão (Chat | Terminal + ⤡)

**Files:**
- Create: `app/CutuqueApp/SessionDetailPane.swift`
- Modify: `app/CutuqueApp/RootSplitView.swift` (apagar o stub `SessionDetailPane`)
- Modify: `app/CutuqueApp/TerminalMirrorView.swift:165-190` (parâmetro `isActive`) e `:206-209` / `:225-228`

**Interfaces:**
- Consumes: `DetailSelection`, `PaneMode`, `NavigationState` (Task 5).
- Produces:
  - `struct SessionDetailPane: View`
  - `TerminalMirrorView(machine:target:title:isActive:)` — `isActive` tem default `true`, então a chamada de `LiveDetailView.swift` (`TerminalMirrorView.swift:456`) segue válida.

- [ ] **Step 1: Dar um interruptor de atividade ao espelho**

O ponto delicado do spec: parar o poll ao sair de vista **sem** disparar `restoreSize()`. A solução é não tirar a view da hierarquia quando se troca Chat↔Terminal — só escondê-la — e desligar o poll por parâmetro. Assim `onDisappear` continua fazendo as duas coisas juntas, e só roda quando o painel inteiro morre, que é "fechar a sessão de verdade".

Em `TerminalMirrorView.swift:165-190`, acrescentar a propriedade e o parâmetro do `init`:

```swift
struct TerminalMirrorView: View {
    let machine: String
    let target: String
    let title: String
    /// Falso quando o espelho está na hierarquia mas escondido (o painel está
    /// no Chat). Para o poll sem desmontar a view — desmontar dispararia o
    /// `restoreSize()`, que só deve rodar ao fechar a sessão de verdade.
    var isActive: Bool = true
```

e no `init` (`:185-190`):

```swift
    init(machine: String, target: String, title: String, isActive: Bool = true) {
        self.machine = machine
        self.target = target
        self.title = title
        self.isActive = isActive
        _model = StateObject(wrappedValue: TerminalMirrorModel(machine: machine, target: target))
    }
```

- [ ] **Step 2: Fazer o poll respeitar `isActive`**

Trocar o `.task(id:)` de `:206-209` por:

```swift
            .task(id: "\(cols)x\(rows)") {
                resizeDebouncer.schedule(cols: cols, rows: rows) { c, r in
                    model.resize(cols: c, rows: r)
                }
                if isActive { model.start() }
            }
            .onChange(of: isActive) { _, active in
                if active { model.start() } else { model.stop() }
            }
```

e acrescentar às propriedades da view (junto de `:174`):

```swift
    /// Segura a rajada de resize do arraste do divisor do Split View.
    @State private var resizeDebouncer = ResizeDebouncer()
```

`ResizeDebouncer` é `@MainActor final class`; guardado em `@State` ele sobrevive aos re-renders sem ser recriado.

`onDisappear` (`:225-228`) **não muda**: continua `stop()` + `restoreSize()`.

- [ ] **Step 3: Escrever o painel**

Create `app/CutuqueApp/SessionDetailPane.swift`:

```swift
import SwiftUI

/// Painel de detalhe de uma sessão no iPad: chat e terminal empilhados, com um
/// seletor no topo.
///
/// Os dois ficam na hierarquia o tempo todo, alternando por opacidade — trocar
/// de aba não remonta nada, então a rolagem do chat e o espelho do tmux
/// sobrevivem à troca. O terminal para de fazer poll por `isActive`, não por
/// desmontagem.
struct SessionDetailPane: View {
    let selection: DetailSelection
    @EnvironmentObject private var nav: NavigationState
    @ObservedObject private var namer = SessionNamesStore.shared

    private var session: Session? {
        if case .session(let s) = selection { return s }
        return nil
    }

    /// Alvo tmux desta seleção: uma entrada ao vivo sempre tem; uma sessão do
    /// registry só se ela roda dentro do tmux.
    private var terminal: (machine: String, target: String, title: String)? {
        switch selection {
        case .live(let entry):
            return (entry.machine, entry.session.id, entry.session.title)
        case .session(let s):
            guard let target = s.tmuxTarget else { return nil }
            return (s.machine, target, namer.displayTitle(for: s))
        }
    }

    private var showsChat: Bool { nav.paneMode == .chat }

    var body: some View {
        ZStack {
            if let session {
                SessionDetailView(session: session)
                    .opacity(showsChat ? 1 : 0)
                    .allowsHitTesting(showsChat)
                    .accessibilityHidden(!showsChat)
            }
            if let terminal {
                TerminalMirrorView(machine: terminal.machine, target: terminal.target,
                                   title: terminal.title, isActive: !showsChat)
                    .opacity(showsChat ? 0 : 1)
                    .allowsHitTesting(!showsChat)
                    .accessibilityHidden(showsChat)
            }
        }
        .toolbar {
            if session != nil, terminal != nil {
                ToolbarItem(placement: .principal) { paneSelector }
            }
            ToolbarItem(placement: .topBarTrailing) { expandButton }
        }
        .onAppear {
            // Seleção sem chat só pode mostrar terminal, e vice-versa.
            if session == nil { nav.paneMode = .terminal }
            else if terminal == nil { nav.paneMode = .chat }
        }
    }

    private var paneSelector: some View {
        Picker("Painel", selection: $nav.paneMode) {
            Text("Chat").tag(PaneMode.chat)
            Text("Terminal").tag(PaneMode.terminal)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
    }

    private var expandButton: some View {
        let expanded = nav.columnVisibility == .detailOnly
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { nav.toggleColumns() }
        } label: {
            Image(systemName: expanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(expanded ? "Recolher para três colunas" : "Expandir o painel")
    }
}
```

- [ ] **Step 4: Apagar o stub**

Em `RootSplitView.swift`, remover a `struct SessionDetailPane` do bloco de stubs temporários (o de `BoardFilterList` fica até a Task 11).

- [ ] **Step 5: Compilar**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 6: Aceite — o resize deixa de ser uma tempestade**

No simulador `Cutuque iPad 13`, com o hub alcançável e uma sessão de tmux viva:

1. Escolher uma sessão do tmux. O seletor **Chat | Terminal** aparece no topo (se a sessão tiver as duas coisas).
2. Ir para **Terminal**. A tela do tmux aparece e atualiza.
3. **Arrastar o divisor** entre a coluna do meio e o detalhe, devagar, de ponta a ponta.
   Expected: **um** `POST /tmux/resize` no fim do arraste, não dezenas. Confira no log do hub:
   `ssh macmini 'docker logs --tail 50 cutuque-hub' | grep -c resize` antes e depois — a diferença deve ser 1 (ou 2, se você parou no meio do caminho).
4. Voltar para **Chat** e para **Terminal** de novo: a tela do tmux ainda está lá, sem "conectando ao terminal…".
5. Girar o iPad com o terminal aberto: o espelho continua vivo, o pane no Mac não muda de tamanho.
6. Trocar para outra sessão: aí sim o pane anterior volta ao tamanho original (`restoreSize`).

- [ ] **Step 7: Commit**

```bash
git add app/CutuqueApp/SessionDetailPane.swift app/CutuqueApp/RootSplitView.swift app/CutuqueApp/TerminalMirrorView.swift
git commit -m "feat(ipad): painel Chat|Terminal com expandir e debounce no resize"
```

---

### Task 9: Fonte do terminal por idiom e poll adaptativo

**Files:**
- Modify: `app/CutuqueApp/TerminalMirrorView.swift:89-98` (poll), `:180-183` (fonte), `:350-362` (botões de fonte)

**Interfaces:**
- Consumes: `TerminalGeometry` (Task 3), `PollPacer` (Task 4).
- Produces: chave `@AppStorage("cutuque.terminalFont.pad")`, separada da atual.

- [ ] **Step 1: Fonte separada por idiom**

Os 10 pt de hoje foram calibrados pros 393 pt do iPhone. Num detalhe de iPad viram letra miúda. Trocar `:180-183`:

```swift
    @AppStorage("cutuque.terminalFont") private var fontPtStored: Double = 10
    private var fontPt: CGFloat { CGFloat(fontPtStored) }
    private let fontMin = 5.0
    private let fontMax = 22.0
```

por:

```swift
    // Duas chaves: o tamanho bom no iPhone (10 pt, 393 pt de largura) é miúdo
    // demais num painel de iPad, e vice-versa. Cada plataforma lembra o seu.
    @AppStorage("cutuque.terminalFont") private var fontPhone: Double = 10
    @AppStorage("cutuque.terminalFont.pad") private var fontPad: Double = 13
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var fontPtStored: Double {
        get { isPad ? fontPad : fontPhone }
        nonmutating set { if isPad { fontPad = newValue } else { fontPhone = newValue } }
    }
    private var fontPt: CGFloat { CGFloat(fontPtStored) }
    private let fontMin = TerminalGeometry.fontMin
    private let fontMax = TerminalGeometry.fontMax
```

O `fontButton` (`:350-362`) já escreve em `fontPtStored`; com o `nonmutating set` ele passa a escrever na chave certa sem mudar nada.

- [ ] **Step 2: Usar a geometria extraída**

Trocar `:196-200`:

```swift
            let cols = max(30, Int((geo.size.width - 16) / (fontPt * 0.62)))
            let rows = max(20, Int((geo.size.height - 120) / (fontPt * 1.28)))
```

por:

```swift
            let cols = TerminalGeometry.columns(width: geo.size.width, fontPt: fontPt)
            let rows = TerminalGeometry.rows(height: geo.size.height, fontPt: fontPt)
```

(Os comentários longos de `:194-199` explicando 0.62 e a reserva de 120 pt migraram para `TerminalGeometry.swift`; pode removê-los daqui.)

- [ ] **Step 3: Poll adaptativo no modelo**

Em `TerminalMirrorModel`, trocar `start()` (`:89-98`) e `refresh()` (`:127-130`) por:

```swift
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var pacer = PollPacer()
            while !Task.isCancelled {
                guard let self else { return }
                let changed = await self.refresh()
                let interval = pacer.interval
                pacer.record(changed: changed, elapsed: interval.seconds)
                try? await Task.sleep(for: interval)
            }
        }
    }
```

```swift
    /// Só atualiza (e re-renderiza) quando a tela realmente muda — evita
    /// re-parsear ANSI à toa a cada poll. Devolve se houve diff, para o pacer.
    @discardableResult
    private func refresh() async -> Bool {
        let s = await api.tmuxScreen(machine: machine, target: target)
        guard !s.isEmpty, s != screen else { return false }
        screen = s
        return true
    }
```

`send()` (`:141`) e `sendKey()` (`:152`) chamam `await refresh()` ignorando o retorno — com `@discardableResult` continuam compilando sem mudança.

`Duration` não tem `.seconds` como `TimeInterval`; acrescentar no fim de `TerminalTiming.swift`:

```swift
extension Duration {
    /// A duração em segundos, para contas de tempo ocioso.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Compilar e rodar os testes**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: exit 0, todos os testes passam.

- [ ] **Step 5: Aceite**

No `Cutuque iPad 13`, terminal aberto: a fonte abre em 13 pt (visivelmente maior que no iPhone) e A−/A+ mudam só a do iPad. Fechar e reabrir mantém o tamanho. No `Cutuque iPhone`, a fonte continua em 10 pt e independente.

Com a tela do tmux parada por mais de 30 s, o intervalo entre requests em `docker logs cutuque-hub` passa de ~1,5 s para ~3 s; ao digitar qualquer coisa, volta a ~1,5 s.

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/TerminalMirrorView.swift app/CutuqueApp/TerminalTiming.swift
git commit -m "feat(terminal): fonte por idiom (13 pt no iPad) e poll adaptativo"
```

---

### Task 10: Teclado físico no terminal

**Files:**
- Create: `app/CutuqueApp/TerminalKeyboard.swift`
- Test: `app/CutuqueAppTests/TerminalKeyboardTests.swift`
- Modify: `app/CutuqueApp/TerminalMirrorView.swift:201-210` (`.onKeyPress`) e `:392-407` (⌘⏎)

**Interfaces:**
- Consumes: nada.
- Produces: `TerminalKeyboard.tmuxKey(for: Character, modifiers: EventModifiers) -> String?` — nil = o caractere é digitado na linha local.

- [ ] **Step 1: Escrever os testes que falham**

Create `app/CutuqueAppTests/TerminalKeyboardTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import CutuqueApp

final class TerminalKeyboardTests: XCTestCase {

    func testLetraComumFicaNaLinhaLocal() {
        // O espelho é polling: mandar letra por letra custaria ~250 ms cada.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "a", modifiers: []))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "Z", modifiers: [.shift]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: " ", modifiers: []))
    }

    func testTeclasDeTerminalVaoDiretoProTmux() {
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.escape.character, modifiers: []), "Escape")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.tab.character, modifiers: []), "Tab")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.upArrow.character, modifiers: []), "Up")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.downArrow.character, modifiers: []), "Down")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.leftArrow.character, modifiers: []), "Left")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.rightArrow.character, modifiers: []), "Right")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.pageUp.character, modifiers: []), "PageUp")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.pageDown.character, modifiers: []), "PageDown")
    }

    func testControleCEDVaoProTmux() {
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: "c", modifiers: [.control]), "C-c")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: "d", modifiers: [.control]), "C-d")
    }

    func testOptionComSetaMoveOCursorNaLinha() {
        // ⌥← e ⌥→ são pra andar dentro do texto que está sendo composto.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.leftArrow.character, modifiers: [.option]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.rightArrow.character, modifiers: [.option]))
    }

    func testEnterNaoEhEncaminhado() {
        // ⏎ envia a linha inteira via send(), não uma tecla solta.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.return.character, modifiers: []))
    }

    func testComandoNuncaEhEncaminhado() {
        // ⌘. ⌘R ⌘T etc. são atalhos do app, não teclas do terminal.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "c", modifiers: [.command]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.escape.character, modifiers: [.command]))
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA na compilação — `cannot find 'TerminalKeyboard' in scope`.

- [ ] **Step 3: Escrever a implementação mínima**

Create `app/CutuqueApp/TerminalKeyboard.swift`:

```swift
import SwiftUI

/// Divisão do teclado físico no espelho de terminal, numa regra só.
///
/// O espelho não é um PTY: é polling de 1,5 s, e `sendKey` custa round-trip
/// mais 250 ms de espera. Digitar caractere-a-caractere está descartado por
/// construção — então caractere imprimível vai pra linha de input local
/// (instantâneo, zero rede) e só tecla com semântica de terminal é encaminhada.
enum TerminalKeyboard {

    /// Nome da tecla no tmux, ou nil se o caractere deve ser digitado na linha.
    static func tmuxKey(for character: Character, modifiers: EventModifiers) -> String? {
        // ⌘ é território dos atalhos do app.
        if modifiers.contains(.command) { return nil }

        if modifiers.contains(.control) {
            switch character {
            case "c": return "C-c"
            case "d": return "C-d"
            default:  break
            }
        }

        // ⌥← / ⌥→ andam dentro do texto sendo composto.
        if modifiers.contains(.option) { return nil }

        switch character {
        case KeyEquivalent.escape.character:    return "Escape"
        case KeyEquivalent.tab.character:       return "Tab"
        case KeyEquivalent.upArrow.character:   return "Up"
        case KeyEquivalent.downArrow.character: return "Down"
        case KeyEquivalent.leftArrow.character: return "Left"
        case KeyEquivalent.rightArrow.character: return "Right"
        case KeyEquivalent.pageUp.character:    return "PageUp"
        case KeyEquivalent.pageDown.character:  return "PageDown"
        default:                                return nil
        }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA, 6 testes novos.

- [ ] **Step 5: Ligar no espelho**

Em `TerminalMirrorView.swift`, na `VStack` do corpo (`:201-205`), acrescentar depois do `.task(id:)`/`.onChange(of: isActive)` da Task 8:

```swift
            .onKeyPress(phases: .down) { press in
                guard let key = TerminalKeyboard.tmuxKey(for: press.key.character,
                                                         modifiers: press.modifiers)
                else { return .ignored }
                Task { await model.sendKey(key) }
                return .handled
            }
```

E, no botão de enviar da `inputBar` (`:392-407`), acrescentar depois do `.disabled(...)`:

```swift
            .keyboardShortcut(.return, modifiers: .command)
```

Nos `fontButton` (`:350-362`), depois do `.disabled(...)`:

```swift
        .keyboardShortcut(delta < 0 ? "-" : "+", modifiers: .command)
```

- [ ] **Step 6: Aceite (e o risco conhecido)**

Com teclado físico ligado ao `Cutuque iPad 13` (Simulador → I/O → Keyboard → **Send Keyboard Input to Device** ligado), terminal aberto:

- digitar `oi` → aparece na barra de input, **não** no tmux;
- `⏎` ou `⌘⏎` → a linha vai pro tmux e o campo esvazia;
- `esc`, `⌃C`, `⇥`, `↑`, `↓`, `←`, `→` → chegam no tmux (na TUI do Claude as setas andam no menu);
- `⌥←` / `⌥→` → andam dentro do texto digitado;
- `⌘+` / `⌘−` → mudam a fonte.

**Risco conhecido:** se o `TextField` da `inputBar` estiver com foco, ele pode consumir as setas antes do `.onKeyPress` do container. Se isso acontecer no teste, mova o mesmo `.onKeyPress` para **cima do próprio `TextField`** (`:382-390`) — ali ele fica antes do campo na cadeia de resposta. Se ainda assim as setas forem engolidas, registre o achado num comentário no board e siga: as teclas da `keyBar` na tela continuam funcionando, e o resto do teclado (letras, ⏎, ⌘) não depende disso.

- [ ] **Step 7: Commit**

```bash
git add app/CutuqueApp/TerminalKeyboard.swift app/CutuqueAppTests/TerminalKeyboardTests.swift app/CutuqueApp/TerminalMirrorView.swift
git commit -m "feat(terminal): teclado físico — linha local, teclas de terminal encaminhadas"
```

---

### Task 11: Atalhos ⌘ globais

**Files:**
- Create: `app/CutuqueApp/CutuqueCommands.swift`
- Modify: `app/CutuqueApp/CutuqueApp.swift` (anexar `.commands` à `WindowGroup`)
- Modify: `app/CutuqueApp/SessionListView.swift` (consumir `.selectSession` e `.newSession`)

**Interfaces:**
- Consumes: `NavigationState`, `AppIntent` (Task 5).
- Produces: `struct CutuqueCommands: Commands`.

- [ ] **Step 1: Escrever a cena de comandos**

Create `app/CutuqueApp/CutuqueCommands.swift`:

```swift
import SwiftUI

/// Atalhos ⌘ do iPad. Além de funcionarem com teclado físico, alimentam
/// sozinhos o painel que o iPadOS mostra ao segurar ⌘ — não precisa de código
/// extra pra isso.
///
/// Os que dependem do contexto de uma view (recarregar o board, focar a busca,
/// abrir a n-ésima sessão) viram `AppIntent` e são consumidos por quem tem o
/// contexto; os que são só estado mexem no `NavigationState` direto.
struct CutuqueCommands: Commands {
    @ObservedObject var nav: NavigationState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nova tarefa") { nav.send(.newSession) }
                .keyboardShortcut("n")
        }

        CommandMenu("Cutuque") {
            Button("Recarregar") { nav.send(.reload) }
                .keyboardShortcut("r")
            Button("Buscar no board") {
                nav.destination = .board
                nav.send(.focusSearch)
            }
            .keyboardShortcut("f")

            Divider()

            Button("Chat / Terminal") {
                nav.paneMode = nav.paneMode == .chat ? .terminal : .chat
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(nav.columnVisibility == .detailOnly ? "Recolher painel" : "Expandir painel") {
                nav.toggleColumns()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Parar o agente") { nav.send(.interrupt) }
                .keyboardShortcut(".")

            Divider()

            Button("Board") { nav.destination = .board }
                .keyboardShortcut("0")
            ForEach(1...9, id: \.self) { n in
                Button("Sessão \(n)") {
                    nav.destination = .sessions
                    nav.send(.selectSession(index: n - 1))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }

            Divider()

            Button("Mover card pra esquerda") { nav.send(.moveCardLeft) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Mover card pra direita") { nav.send(.moveCardRight) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }
}
```

- [ ] **Step 2: Anexar à cena**

Em `CutuqueApp.swift`, depois do fecha-chaves da `WindowGroup` e antes do `.onChange(of: scenePhase)`:

```swift
        .commands { CutuqueCommands(nav: nav) }
```

- [ ] **Step 3: Consumir os intents da lista de sessões**

Em `SessionListView.swift`, acrescentar às propriedades:

```swift
    @EnvironmentObject private var nav: NavigationState
```

e, junto dos outros `.onChange` do corpo (depois de `:599`):

```swift
        // Atalhos ⌘ que precisam da lista carregada pra acontecer.
        //
        // Só consome o que ELE trata: a lista e o painel de detalhe ficam vivos
        // ao mesmo tempo (colunas diferentes da split view), então zerar o
        // intent no `default` faria a lista engolir o ⌘. antes do chat ver.
        .onChange(of: nav.intent) { _, intent in
            switch intent {
            case .newSession:
                showingNew = true
            case .reload:
                Task { await model.refresh(); await model.refreshLive() }
            case .selectSession(let index):
                // ⌘1…⌘9 na ordem em que a lista aparece: precisa de você, ao
                // vivo, depois as demais ativas.
                let ordered = needsYou + activeOthers
                if let session = ordered[safe: index] {
                    splitSelection?.wrappedValue = .session(session)
                }
            default:
                return
            }
            nav.consume()
        }
```

`nav` é `@EnvironmentObject` e o `RootTabView` do iPhone também o recebe (o `CutuqueApp` injeta nos dois ramos), então a lista compila e funciona nos dois.

Acrescentar o subscript seguro no fim de `SessionListView.swift`:

```swift
private extension Array {
    /// Índice que não estoura — ⌘5 numa lista de 3 sessões simplesmente não faz nada.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 4: Compilar**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 5: Aceite**

No `Cutuque iPad 13` com teclado físico:
- **segurar ⌘** mostra o painel de atalhos com o menu "Cutuque" e todos os itens listados;
- `⌘N` abre Nova tarefa; `⌘R` recarrega; `⌘0` vai pro Board; `⌘3` seleciona a terceira sessão da lista; `⌘⇧T` alterna Chat/Terminal; `⌘⌃F` expande e recolhe;
- `⌘5` com só duas sessões na lista: nada acontece, sem crash;
- `⌘.` ainda **não faz nada** — o consumidor dele é a Task 15. `⌘←`/`⌘→`, a Task 14. Aparecerem no painel do ⌘ sem efeito, nesta task, é o esperado.

- [ ] **Step 6: Commit**

```bash
git add app/CutuqueApp/CutuqueCommands.swift app/CutuqueApp/CutuqueApp.swift app/CutuqueApp/SessionListView.swift
git commit -m "feat(ipad): atalhos de teclado e menu do ⌘"
```

---

### Task 12: Lógica do board (funções puras)

Tudo que o drag & drop e o teclado do board precisam decidir, isolado e testado antes de encostar na view.

**Files:**
- Create: `app/CutuqueApp/BoardMoveLogic.swift`
- Test: `app/CutuqueAppTests/BoardMoveLogicTests.swift`

**Interfaces:**
- Consumes: `BoardTask`, `BoardColumn` (`Models.swift:331` e `:380`).
- Produces:
  - `enum BoardDropTarget: Equatable` — `.column(BoardColumn)`, `.encalhadas`
  - `enum BoardMovePlan: Equatable` — `.move(BoardColumn)`, `.markEncalhada`
  - `BoardMoveLogic.plan(for: BoardTask, target: BoardDropTarget) -> BoardMovePlan?`
  - `BoardMoveLogic.apply(_: BoardMovePlan, to: [BoardTask], id: String) -> [BoardTask]`
  - `BoardMoveLogic.adjacentColumn(from: BoardColumn, offset: Int) -> BoardColumn?`
  - `BoardLayout.columnWidth(available: CGFloat, columns: Int, isRegular: Bool) -> CGFloat`

- [ ] **Step 1: Escrever os testes que falham**

Create `app/CutuqueAppTests/BoardMoveLogicTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

final class BoardMoveLogicTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String = "abc", column: String = "a_fazer",
                      encalhada: Bool = false, archived: Bool = false) -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"\(column)","group":"g","session":"s",
         "encalhada":\(encalhada),"archived":\(archived)}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    // MARK: plano

    func testCardArquivadoNaoSeMove() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .column(.feito)))
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .encalhadas))
    }

    func testSoltarNaPropriaColunaNaoFazNada() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(column: "feito"), target: .column(.feito)))
    }

    func testMoverParaOutraColunaEhUmaChamadaSo() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer"), target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testSairDeEncalhadasEhUmaChamadaSo() {
        // O hub limpa a flag sozinho no move (postgres.go:281).
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testEncalhadaVoltandoParaAFazerAindaEhUmMove() {
        // Mesma coluna, mas precisa limpar a flag — não pode virar no-op.
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.aFazer)),
                       .move(.aFazer))
    }

    func testMarcarComoEncalhada() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "em_progresso"), target: .encalhadas),
                       .markEncalhada)
    }

    func testJaEncalhadaNaoRemarca() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(encalhada: true), target: .encalhadas))
    }

    // MARK: aplicação otimista

    func testAplicarMoveTrocaAColunaELimpaAFlag() {
        let antes = [task(id: "a", column: "a_fazer", encalhada: true)]
        let depois = BoardMoveLogic.apply(.move(.feito), to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "feito")
        XCTAssertEqual(depois[0].isEncalhada, false)
    }

    func testAplicarEncalhadaForcaAFazer() {
        let antes = [task(id: "a", column: "em_revisao")]
        let depois = BoardMoveLogic.apply(.markEncalhada, to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "a_fazer")
        XCTAssertEqual(depois[0].isEncalhada, true)
    }

    func testAplicarNumIdInexistenteNaoMexeEmNada() {
        let antes = [task(id: "a")]
        XCTAssertEqual(BoardMoveLogic.apply(.move(.feito), to: antes, id: "zzz"), antes)
    }

    // MARK: teclado

    func testColunaAdjacente() {
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: 1), .emProgresso)
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .emProgresso, offset: -1), .aFazer)
    }

    func testColunaAdjacenteNaoDaVoltaNoBoard() {
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: -1))
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .concluido, offset: 1))
    }

    // MARK: largura de coluna

    func testNoIPhoneAColunaContinuaPaginando() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 393, columns: 5, isRegular: false),
                       393 * 0.86, accuracy: 0.01)
    }

    func testNoIPadAsColunasDividemALargura() {
        // 1366 - 7 gutters de 12 = 1282 / 6 = 213,7 → cai no piso de 260.
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 6, isRegular: true), 260)
    }

    func testColunaLargaQuandoSobraEspaco() {
        // 1366 - 4 gutters = 1318 / 3 = 439,3
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 3, isRegular: true),
                       439.33, accuracy: 0.1)
    }

    func testZeroColunasNaoDivideProZero() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 0, isRegular: true),
                       1366 * 0.86, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd app && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: FALHA na compilação — `cannot find 'BoardMoveLogic' in scope`.

- [ ] **Step 3: Escrever a implementação mínima**

Create `app/CutuqueApp/BoardMoveLogic.swift`:

```swift
import CoreGraphics

/// Onde um card pode ser solto. "Encalhadas" não é coluna do hub — é o
/// predicado `encalhada == true` — mas no board é uma faixa como as outras.
enum BoardDropTarget: Equatable {
    case column(BoardColumn)
    case encalhadas
}

/// O que fazer de fato. Duas ações distintas na API: mover (que já limpa a
/// flag de encalhada no hub) e marcar como encalhada (que já força `a_fazer`).
enum BoardMovePlan: Equatable {
    case move(BoardColumn)
    case markEncalhada
}

enum BoardMoveLogic {

    /// Decide a ação de soltar `task` em `target`. Nil = nada a fazer: card
    /// arquivado (só leitura) ou já está exatamente onde caiu.
    static func plan(for task: BoardTask, target: BoardDropTarget) -> BoardMovePlan? {
        if task.archived == true { return nil }
        switch target {
        case .encalhadas:
            return task.isEncalhada ? nil : .markEncalhada
        case .column(let column):
            // Card encalhado tem `column == "a_fazer"`, mas soltar ele em
            // "A fazer" ainda é um move — é assim que a flag some.
            if task.column == column.rawValue && !task.isEncalhada { return nil }
            return .move(column)
        }
    }

    /// Aplica o plano na lista local, antes da rede responder. É o que impede
    /// o card de voltar visivelmente pra origem enquanto o `load()` não chega.
    static func apply(_ plan: BoardMovePlan, to tasks: [BoardTask], id: String) -> [BoardTask] {
        var out = tasks
        guard let i = out.firstIndex(where: { $0.id == id }) else { return out }
        switch plan {
        case .move(let column):
            out[i].column = column.rawValue
            out[i].encalhada = false
        case .markEncalhada:
            out[i].column = BoardColumn.aFazer.rawValue
            out[i].encalhada = true
        }
        return out
    }

    /// Coluna vizinha, para ⌘← / ⌘→. Nil nas pontas — o board não dá a volta.
    static func adjacentColumn(from column: BoardColumn, offset: Int) -> BoardColumn? {
        guard let i = BoardColumn.allCases.firstIndex(of: column) else { return nil }
        let target = i + offset
        guard BoardColumn.allCases.indices.contains(target) else { return nil }
        return BoardColumn.allCases[target]
    }
}

enum BoardLayout {
    /// Abaixo disto o título do card quebra em três linhas e o kanban vira
    /// ilegível — melhor deixar rolar na horizontal.
    static let minColumnWidth: CGFloat = 260
    static let spacing: CGFloat = 12

    /// No iPhone (compacto) a coluna ocupa ~86% e o board pagina no swipe, como
    /// hoje. No iPad divide a largura entre as colunas visíveis, com piso.
    static func columnWidth(available: CGFloat, columns: Int, isRegular: Bool) -> CGFloat {
        guard isRegular, columns > 0 else { return available * 0.86 }
        let gutters = spacing * CGFloat(columns + 1)
        return max(minColumnWidth, (available - gutters) / CGFloat(columns))
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: PASSA, 16 testes novos.

- [ ] **Step 5: Commit**

```bash
git add app/CutuqueApp/BoardMoveLogic.swift app/CutuqueAppTests/BoardMoveLogicTests.swift app/CutuqueApp.xcodeproj
git commit -m "feat(board): lógica pura de movimento, colunas vizinhas e largura"
```

---

### Task 13: Board em colunas lado a lado, filtros na coluna do meio e inspector

**Files:**
- Create: `app/CutuqueApp/BoardFilterList.swift`
- Modify: `app/CutuqueApp/BoardView.swift` (`:87-225` corpo, `:174-196` `boardScroller`, `:433-443` `BoardTaskDetailView`, `:569-575` `ArchiveView`)
- Modify: `app/CutuqueApp/RootSplitView.swift` (apagar o stub `BoardFilterList`)

**Interfaces:**
- Consumes: `BoardLayout` (Task 12), `NavigationState` (Task 5), `BoardModel` do ambiente (Task 7).
- Produces:
  - `struct BoardFilterList: View`
  - `BoardTaskDetailView(task:model:readOnly:onClose:)` — `onClose` opcional, default nil = comportamento de hoje
  - `ArchiveView(embedded:selection:)` funcional

- [ ] **Step 1: Fazer o detalhe do card saber fechar de duas formas**

Dentro de um `.inspector`, `@Environment(\.dismiss)` não fecha nada. `readOnly` já existe (`:436`); o que falta é uma saída alternativa. Em `BoardView.swift`, inserir **uma** propriedade entre `readOnly` (`:436`) e `dismiss` (`:437`):

```swift
    /// Quando não-nil, fechar é responsabilidade de quem apresentou (inspector).
    /// Nil = sheet, e o `dismiss` do ambiente resolve, como sempre.
    var onClose: (() -> Void)?
```

Ficando assim:

```swift
struct BoardTaskDetailView: View {
    let task: BoardTask
    @ObservedObject var model: BoardModel
    var readOnly: Bool = false   // cards arquivados: só leitura (sem mover/apagar/comentar)
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
```

e acrescentar o método, logo antes de `var body`:

```swift
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
```

Trocar **todas** as chamadas de `dismiss()` dentro desta struct por `close()`: `:466` (mover), `:475` (encalhada), `:543` (botão Fechar) e `:546` (apagar). São quatro.

- [ ] **Step 2: Colunas lado a lado no iPad**

Trocar `boardScroller` (`:174-196`):

```swift
    private var boardScroller: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width * 0.86
```

por:

```swift
    /// No iPhone as colunas paginam no swipe (~86% cada). No iPad elas dividem
    /// a largura e ficam todas visíveis, que é o ponto de ter tela grande.
    private var boardScroller: some View {
        GeometryReader { geo in
            let isRegular = horizontalSizeClass == .regular
            let visibleColumns = BoardColumn.allCases.count + (model.encalhadas.isEmpty ? 0 : 1)
            let colWidth = BoardLayout.columnWidth(available: geo.size.width,
                                                   columns: visibleColumns,
                                                   isRegular: isRegular)
```

e trocar `.scrollTargetBehavior(.viewAligned)` (`:193`) por:

```swift
            // Paginação só no compacto: no iPad as colunas já cabem juntas e o
            // "encaixe" por coluna atrapalharia o arraste de card.
            .modifier(PagingWhenCompact(enabled: !isRegular))
```

`.scrollTargetBehavior` devolve tipos concretos diferentes, então não dá pra escolher com um ternário inline — o ramo tem que estar dentro de um `ViewModifier`. Acrescentar no fim de `BoardView.swift`:

```swift
/// `.scrollTargetBehavior` não é condicionável inline (os behaviors são tipos
/// concretos distintos); este modifier resolve com um `if` de verdade.
private struct PagingWhenCompact: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.scrollTargetBehavior(.viewAligned) } else { content }
    }
}
```

Acrescentar às propriedades da `BoardView` (junto de `:88`):

```swift
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
```

- [ ] **Step 3: Detalhe do card no inspector**

Trocar o `.sheet(item: $selected)` (`:156-158`) por:

```swift
            .inspector(isPresented: Binding(get: { selected != nil },
                                            set: { if !$0 { selected = nil } })) {
                if let task = selected {
                    BoardTaskDetailView(task: task, model: model,
                                        readOnly: task.archived == true,
                                        onClose: { selected = nil })
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                } else {
                    // O inspector precisa de conteúdo mesmo fechado.
                    Color.clear
                }
            }
```

`.inspector` em largura compacta (iPhone, Slide Over) se apresenta sozinho como sheet — é o comportamento nativo, não precisa de ramo por idiom.

`BoardTaskDetailView` embrulha o próprio conteúdo numa `NavigationStack` (`:445`); dentro do inspector isso continua válido e dá título e o botão Fechar.

- [ ] **Step 4: Tirar a busca de cima do board**

Hoje a busca **substitui** o board inteiro (`:100-101`). No iPad ela passa a ocupar a coluna do meio; o kanban continua visível. Trocar o `Group` do corpo (`:99-115`) por:

```swift
            Group {
                if isSearching && horizontalSizeClass != .regular {
                    // Compacto: a busca ainda toma a tela, como sempre foi.
                    searchResultsView
                } else {
                    VStack(spacing: 0) {
                        // No iPad os filtros moram na coluna do meio.
                        if horizontalSizeClass != .regular {
                            FilterBar(model: model)
                            Divider()
                        }
                        if model.isLoading && model.tasks.isEmpty {
                            Spacer(); ProgressView(); Spacer()
                        } else if model.tasks.isEmpty, let err = model.errorText {
                            Spacer(); ContentUnavailableView(err, systemImage: "wifi.exclamationmark"); Spacer()
                        } else {
                            boardScroller
                        }
                    }
                }
            }
```

`FilterBar` é `private struct` (`:229`) — para o `BoardFilterList` usá-la, tirar o `private`:

```swift
struct FilterBar: View {
```

E idem em `FilterMenu` (`:252`).

- [ ] **Step 5: Escrever a coluna do meio**

Create `app/CutuqueApp/BoardFilterList.swift`:

```swift
import SwiftUI

/// Coluna do meio quando o destino é o Board: os três eixos de filtro visíveis
/// ao mesmo tempo (no iPhone eles vivem espremidos numa barra horizontal) e a
/// busca, que aqui não cobre mais o kanban.
struct BoardFilterList: View {
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var nav: NavigationState
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        List {
            Section("Buscar") {
                TextField("Título, descrição, comentários…", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !model.searchResults.isEmpty {
                    ForEach(model.searchResults) { task in
                        Button { nav.boardSelection = task } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if task.archived == true {
                                    Text("ARQUIVADO").font(.caption2).fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                }
                                BoardCardRow(task: task)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Ambiente") { filterRows(selection: $model.filterGroup, options: model.groups) }
            Section("Tipo")     { filterRows(selection: $model.filterType,  options: model.types) }
            Section("Sessão")   { filterRows(selection: $model.filterSession, options: model.sessions) }

            if model.hasActiveFilter {
                Section {
                    Button(role: .destructive) {
                        model.filterGroup = "all"; model.filterType = "all"; model.filterSession = "all"
                    } label: {
                        Label("Limpar filtros", systemImage: "xmark.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("Board")
        .onChange(of: searchText) { _, q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { await model.search(q) }
            }
        }
        // Só consome o que trata — o board (coluna de detalhe) está vivo junto
        // e precisa receber o ⌘← / ⌘→.
        .onChange(of: nav.intent) { _, intent in
            switch intent {
            case .focusSearch: searchFocused = true
            default:           return
            }
            nav.consume()
        }
    }

    @ViewBuilder
    private func filterRows(selection: Binding<String>, options: [String]) -> some View {
        Button { selection.wrappedValue = "all" } label: {
            HStack {
                Text("Todos")
                Spacer()
                if selection.wrappedValue == "all" { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .buttonStyle(.plain)
        ForEach(options, id: \.self) { option in
            Button { selection.wrappedValue = option } label: {
                HStack {
                    Text(option)
                    Spacer()
                    if selection.wrappedValue == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
```

`nav.boardSelection` ainda não existe. Acrescentar em `NavigationState.swift`, junto de `archiveSelection`:

```swift
    /// Card aberto no inspector do board (também alimentado pela busca).
    @Published var boardSelection: BoardTask?
```

E em `BoardView.swift`, trocar `@State private var selected: BoardTask?` (`:89`) por leitura do estado compartilhado, para a busca da coluna do meio conseguir abrir o card:

```swift
    @EnvironmentObject private var nav: NavigationState
    private var selected: BoardTask? {
        get { nav.boardSelection }
        nonmutating set { nav.boardSelection = newValue }
    }
```

- [ ] **Step 6: Arquivo como destino**

Em `ArchiveView` (`:569-620`), usar os parâmetros criados na Task 7. Trocar o corpo:

```swift
    var body: some View {
        NavigationStack {
            Group {
```

por:

```swift
    var body: some View {
        Group {
            if embedded { archiveList } else { NavigationStack { archiveList } }
        }
        .task {
            loading = true
            weeks = (try? await api.boardArchive()) ?? []
            loading = false
        }
    }

    @ViewBuilder private var archiveList: some View {
        Group {
```

e no fim do que era o corpo, trocar a toolbar e a sheet (`:608-619`) por:

```swift
        .navigationTitle("Arquivo semanal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
        }
        .sheet(item: embedded ? .constant(nil) : $selected) { t in
            BoardTaskDetailView(task: t, model: roModel, readOnly: true)
        }
    }
```

e, nas linhas de card (`:592`), publicar no binding quando embutido:

```swift
                                            Button {
                                                if let selection { selection.wrappedValue = t }
                                                else { selected = t }
                                            } label: { BoardCardRow(task: t) }
                                                .buttonStyle(.plain)
```

- [ ] **Step 7: Apagar o stub e compilar**

Em `RootSplitView.swift`, remover o bloco inteiro "Stubs temporários".

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: exit 0, todos os testes passam.

- [ ] **Step 8: Aceite**

No `Cutuque iPad 13`, sidebar → **Board**:
- as cinco colunas (mais Encalhadas, se houver) aparecem **juntas**, sem swipe;
- a coluna do meio mostra Ambiente, Tipo e Sessão **os três ao mesmo tempo**, cada um com seus valores;
- tocar num card abre o inspector **à direita** — o board continua visível, não é tapado;
- buscar na coluna do meio: o kanban continua atrás, e escolher um resultado abre o card no inspector;
- `Fechar` no inspector fecha só o inspector.

No `Cutuque iPhone`: board igual a antes — barra de filtros horizontal, swipe entre colunas, busca cobrindo a tela, card abrindo em sheet.

- [ ] **Step 9: Commit**

```bash
git add app/CutuqueApp/BoardFilterList.swift app/CutuqueApp/BoardView.swift app/CutuqueApp/NavigationState.swift app/CutuqueApp/RootSplitView.swift
git commit -m "feat(board): colunas lado a lado, filtros na coluna do meio e inspector"
```

---

### Task 14: Drag & drop otimista e ⌘←/⌘→

**Files:**
- Modify: `app/CutuqueApp/BoardView.swift` (`:29-32` `move`, `:174-196` colunas, `:287-344` `BoardColumnCard`, `:348-399` `BoardCardRow`)

**Interfaces:**
- Consumes: `BoardMoveLogic`, `BoardDropTarget` (Task 12); `NavigationState.intent` (Task 5).
- Produces: `BoardModel.drop(_ task: BoardTask, on target: BoardDropTarget) async`.

- [ ] **Step 1: Movimento otimista no modelo**

Em `BoardModel` (`BoardView.swift:29-32`), **manter** o `move` de hoje (o botão do inspector usa) e acrescentar depois dele:

```swift
    /// Arraste: move na hora, na lista local, e só então fala com o hub. Sem
    /// isto o card voltaria visivelmente pra origem antes de reaparecer no
    /// destino — o board não tem WebSocket, toda ação recarrega tudo.
    func drop(_ task: BoardTask, on target: BoardDropTarget) async {
        guard let plan = BoardMoveLogic.plan(for: task, target: target) else { return }
        let snapshot = tasks
        tasks = BoardMoveLogic.apply(plan, to: tasks, id: task.id)
        do {
            switch plan {
            case .move(let column):
                try await api.moveBoardTask(id: task.id, column: column.rawValue)
            case .markEncalhada:
                try await api.setBoardEncalhada(id: task.id, true)
            }
            await load()
        } catch {
            tasks = snapshot
            errorText = "Não consegui mover o card — ele voltou pro lugar."
        }
    }

    /// Acha o card pelo id (o arraste carrega só o id, que é o que `String`
    /// sabe transferir sem conformidade nova).
    func task(id: String) -> BoardTask? { tasks.first { $0.id == id } }
```

- [ ] **Step 2: Tornar o card arrastável**

Em `BoardCardRow` (`:348-399`), no fim da cadeia de modificadores (depois de `.contentShape(Rectangle())`, `:390`), acrescentar:

```swift
        // Card arquivado é só leitura — não arrasta.
        .modifier(DraggableCard(id: task.id, enabled: task.archived != true))
```

O arraste carrega só o **id** (`String` já sabe se transferir; `BoardTask` precisaria de `Transferable`). E, como `.draggable` muda o tipo da view, o "arrasta ou não" tem que estar dentro de um `ViewModifier` em vez de um ternário. Acrescentar no fim de `BoardView.swift`:

```swift
/// `.draggable` muda o tipo da view, então não dá pra aplicá-lo condicionalmente
/// inline. Card arquivado passa direto, sem virar fonte de arraste.
private struct DraggableCard: ViewModifier {
    let id: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}
```

- [ ] **Step 3: Tornar a coluna um destino de drop**

`BoardColumnCard` (`:287-344`) ganha o alvo e o realce. Acrescentar às propriedades:

```swift
    let target: BoardDropTarget
    let onDrop: (String) -> Void
    @State private var isTargeted = false
```

e no fim da cadeia de modificadores (depois de `.clipShape(...)`, `:342`):

```swift
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            onDrop(id)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor, lineWidth: isTargeted ? 2.5 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
```

- [ ] **Step 4: Ligar as chamadas no `boardScroller`**

Trocar as duas construções de `BoardColumnCard` (`:179-187`) por:

```swift
                    if !model.encalhadas.isEmpty {
                        BoardColumnCard(title: "Encalhadas", count: model.encalhadas.count,
                                        alert: true, tasks: model.encalhadas, width: colWidth,
                                        target: .encalhadas,
                                        onDrop: { id in
                                            guard let t = model.task(id: id) else { return }
                                            Task { await model.drop(t, on: .encalhadas) }
                                        }) { selected = $0 }
                    }
                    ForEach(BoardColumn.allCases) { column in
                        let items = model.inColumn(column)
                        BoardColumnCard(title: column.label, count: items.count,
                                        alert: false, tasks: items, width: colWidth,
                                        target: .column(column),
                                        onDrop: { id in
                                            guard let t = model.task(id: id) else { return }
                                            Task { await model.drop(t, on: .column(column)) }
                                        }) { selected = $0 }
                    }
```

- [ ] **Step 5: ⌘← e ⌘→ movem o card aberto**

Em `BoardView`, junto dos outros `.onChange` do corpo:

```swift
            // ⌘← / ⌘→ movem o card aberto no inspector — mesmo caminho otimista
            // do arraste. Só consome o que trata (a coluna de filtros também
            // escuta o intent e espera pelo ⌘F dela).
            .onChange(of: nav.intent) { _, intent in
                let offset: Int
                switch intent {
                case .moveCardLeft:  offset = -1
                case .moveCardRight: offset = 1
                case .reload:
                    Task { await model.load() }
                    nav.consume()
                    return
                default:
                    return
                }
                nav.consume()
                guard let task = selected,
                      let current = BoardColumn(rawValue: task.column),
                      let destination = BoardMoveLogic.adjacentColumn(from: current, offset: offset)
                else { return }
                Task { await model.drop(task, on: .column(destination)) }
            }
```

- [ ] **Step 6: Compilar e rodar os testes**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: exit 0, todos os testes passam.

- [ ] **Step 7: Aceite**

No `Cutuque iPad 13`, Board, com o hub alcançável:
- arrastar um card de "A fazer" para "Em progresso": ele **fica** no destino na hora, sem piscar de volta;
- a coluna sob o dedo ganha um contorno na cor do tema;
- arrastar para **Encalhadas**: o card vira encalhado (triângulo vermelho) e vai pra faixa de Encalhadas;
- arrastar **de** Encalhadas para uma coluna: sai de encalhado numa tacada só — confira no hub que houve **um** request, não dois:
  `ssh macmini 'docker logs --tail 30 cutuque-hub' | grep -E 'board.*(move|encalhada)'`
- soltar um card na própria coluna: nada acontece, nenhum request;
- **derrubar a rede** (desligar o Wi-Fi do simulador ou parar o hub) e arrastar: o card volta pra origem e aparece "Não consegui mover o card — ele voltou pro lugar.";
- na busca, um resultado **ARQUIVADO** não arrasta;
- com um card aberto no inspector, `⌘→` move ele uma coluna pra direita; na última coluna, `⌘→` não faz nada.

- [ ] **Step 8: Commit**

```bash
git add app/CutuqueApp/BoardView.swift
git commit -m "feat(board): drag & drop com movimento otimista e ⌘←/⌘→"
```

---

### Task 15: `⌘.` para o agente

O atalho é emitido pela Task 11 e, até aqui, ninguém o consome — quem sabe interromper é o `SessionDetailViewModel`, que vive dentro da `SessionDetailView`.

**Files:**
- Modify: `app/CutuqueApp/SessionDetailView.swift` (propriedades da `SessionDetailView`, `:194+`, e os modificadores do corpo)

**Interfaces:**
- Consumes: `NavigationState`, `AppIntent.interrupt` (Task 5); `SessionDetailViewModel.interrupt()` (`SessionDetailView.swift:113`).
- Produces: nenhuma API nova.

- [ ] **Step 1: Escutar o intent no chat**

Em `SessionDetailView`, acrescentar às propriedades:

```swift
    @EnvironmentObject private var nav: NavigationState
```

e, junto dos outros modificadores do corpo (depois de `.navigationBarTitleDisplayMode(.inline)`):

```swift
        // ⌘. — mesmo caminho do botão de parar. Só consome o que trata: a lista
        // de sessões está viva na outra coluna e espera pelos intents dela.
        .onChange(of: nav.intent) { _, intent in
            guard intent == .interrupt else { return }
            nav.consume()
            Task { await model.interrupt() }
        }
```

Confirme o nome da propriedade do view model nesta struct (`model` no `@StateObject` do `init(session:)`) e use o mesmo.

- [ ] **Step 2: Compilar**

Run: `cd app && xcodegen generate && xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 3: Aceite**

No `Cutuque iPad 13` com teclado físico, uma sessão rodando aberta no chat:
- `⌘.` para o agente e mostra o mesmo aviso do botão de parar (`"pausada"` no tmux, `"encerrada"` no pipe — ver `interrupt()` em `:113`);
- `⌘.` com o **Board** aberto: nada acontece, sem crash;
- `⌘.` com o chat aberto **e** a lista de sessões visível ao lado: o chat recebe — a lista não engole o atalho.

- [ ] **Step 4: Commit**

```bash
git add app/CutuqueApp/SessionDetailView.swift
git commit -m "feat(ipad): ⌘. para o agente pelo chat"
```

---

### Task 16: Largura compacta (Slide Over e Split View estreito)

A última fase do spec. Nada de novo — é caçar o que quebra em ~320 pt e consertar.

**Files:**
- Modify: até 3 arquivos, conforme o que a inspeção achar (candidatos: `SessionDetailPane.swift`, `TerminalMirrorView.swift`, `BoardView.swift`)

**Interfaces:**
- Consumes: tudo das tasks anteriores.
- Produces: nenhuma API nova.

- [ ] **Step 1: Reproduzir o Slide Over**

No `Cutuque iPad 13`, abrir o Cutuque, depois abrir outro app (Ajustes) e arrastar o Cutuque para Slide Over — ou usar Split View e arrastar o divisor até o Cutuque ficar no mínimo.

Em Slide Over o `horizontalSizeClass` vira `.compact` e a `NavigationSplitView` colapsa numa pilha. O idiom continua `.pad`, então a raiz **não** troca — é isso que queremos.

- [ ] **Step 2: Percorrer a lista de verificação e anotar o que quebra**

| O quê | Esperado |
|---|---|
| Sidebar → Sessões → uma sessão | empurra a lista e mostra o chat, com botão de voltar |
| Seletor Chat \| Terminal | cabe na barra; se não couber, some o `.frame(maxWidth: 220)` do `paneSelector` |
| Terminal | ~30–40 colunas (o piso de `TerminalGeometry.minColumns` segura); a `keyBar` rola na horizontal como no iPhone |
| Botão ⤡ | ainda visível na toolbar (em compacto ele não tem o que expandir — pode ficar sem efeito, mas não pode sumir a toolbar inteira nem crashar) |
| Board | volta a paginar no swipe (`horizontalSizeClass == .compact` → `BoardLayout` devolve 86%) |
| Inspector do card | apresenta-se como sheet, comportamento nativo do `.inspector` em compacto |
| Filtros | o `BoardFilterList` da coluna do meio fica sendo a tela do meio da pilha — os três eixos continuam ali |
| Girar em Slide Over | nada remonta; o terminal continua vivo |

- [ ] **Step 3: Consertar o que aparecer**

Regras: mudança **só** dentro dos ramos de `horizontalSizeClass == .compact`; nada pode alterar o caminho regular já aceito nas tasks anteriores; no máximo 3 arquivos — se precisar de mais, pare e quebre em duas tasks.

Se **nada** quebrar, esta task não tem diff de código — registre isso no commit e no board, não invente mudança.

- [ ] **Step 4: Rodar a suíte inteira e o iPhone**

Run: `cd app && xcodegen generate && xcodebuild test -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,name=Cutuque iPad 13' -quiet`
Expected: exit 0, todos os testes passam.

Depois, no `Cutuque iPhone`: passar por Sessões → chat → terminal → Board → card → busca → Ajustes. Nada pode ter mudado desde o começo do plano.

- [ ] **Step 5: Commit**

```bash
git add -A app/
git commit -m "fix(ipad): ajustes de largura compacta (Slide Over e Split View estreito)"
```

---

## Fora deste plano

Do spec, "Fora de escopo": múltiplas janelas e Stage Manager, Apple Pencil, monitor externo, arrastar cards pra fora do app, Catalyst/macOS, reescrever o terminal como PTY.

Acrescentado durante o planejamento, também fora:

- **Tab bar só em retrato no iPad.** Continua possível depois, isolada, sem mexer na raiz (o spec já previa).
- **Apertar o ATS** (`NSAllowsArbitraryLoads`, `project.yml:53`) e capturas de tela de iPad pro App Store. São pendências de submissão que este trabalho **torna mais urgentes** (o App Review passa a testar em iPad), mas não bloqueiam dev nem TestFlight. Tratar junto com o ATS antes de submeter.
- **Histórico, Hub e Ajustes como colunas.** Ficam em sheet a partir da sidebar. Viraria reescrita de quatro views que hoje se apresentam sozinhas com `NavigationStack` e botão Fechar — custo sem retorno para telas de consulta pontual.
- **Navegação ↑↓←→ entre cards do board.** O spec cita junto de ⌘←/⌘→. Ficou de fora: precisa de um conceito de "card com foco" separado do card aberto no inspector, e o inspector já dá o alvo inequívoco que ⌘←/⌘→ precisam. `esc` fechando o inspector também não entrou — o botão Fechar cobre.
