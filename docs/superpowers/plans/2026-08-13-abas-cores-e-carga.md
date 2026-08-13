# Abas de navegador, cor de destaque e carga das vivas — plano de implementação

> **Para agentes:** SUB-SKILL OBRIGATÓRIA: use `superpowers:subagent-driven-development` (recomendado)
> ou `superpowers:executing-plans` para executar tarefa por tarefa. Os passos usam `- [ ]`.

**Objetivo:** fechar os seis apontamentos da Vanessa na 2.6.0 — aba que abre ao lado (não substitui),
cor de destaque que realmente pinta, uma barra de chrome com seletor e tela cheia para toda aba,
aparência da máquina alcançável em dois lugares, e a lista de sessões ao vivo pintando em ~1 s em vez
de 11 s.

**Arquitetura:** uma onda 0 do orquestrador entrega o vocabulário compartilhado (valor de ambiente
`corDeDestaque`, registro `SegmentoDeChrome` em `NavigationState`, a view `ChromeDaAba` costurada em
`abasDetail`, e a grade de ícones extraída para componente). Com isso no lugar, seis frentes trabalham
em paralelo em **arquivos disjuntos** — nenhuma frente edita arquivo de outra.

**Stack:** SwiftUI (iOS 17.0), XCTest, `xcodegen`. Sem dependência nova.

Spec: `docs/superpowers/specs/2026-08-13-abas-cores-e-carga-design.md`

## Restrições globais

Valem para **todas** as tarefas:

- **pt-BR** em código, comentários, testes e texto de UI. Nomes de tipo/função em pt-BR quando novos.
- **`git add` sempre com caminho explícito. NUNCA `git add -A` nem `git add .`** — `scripts/tmx.sh`
  aparece como ` M` no checkout da Vanessa e não pode ser commitado por ninguém. Não commitar
  `app/Local.xcconfig`, `app/project-notest-watch.yml`, `app/CutuqueAppNoWatch.xcodeproj`.
- **Nunca apagar comentário que documenta bug ou decisão de arquitetura.** Se a mudança o tornar
  falso, **reescreva** com a razão nova e a data (13/08/2026).
- **Não mexer no piso do SwiftTerm** (`project.yml`: `from: 1.18.0`) nem em versão/build.
- **Preservar cores semânticas**: vermelho de destruir, verde de sucesso, laranja de aviso, paleta de
  `RealceDeSintaxe.swift`, `.white` de contraste sobre fundo colorido. A varredura só troca o que é
  **ação primária, seleção ou identidade**.
- Testes rodam no projeto sem watch: `xcodegen generate --spec project-notest-watch.yml` (gera
  `CutuqueAppNoWatch.xcodeproj`) e
  `xcodebuild test -project CutuqueAppNoWatch.xcodeproj -scheme CutuqueApp -destination 'platform=iOS Simulator,id=<UDID>'`
  com `timeout: 600000`. iPad de referência: `E90308CB-9E6B-43C1-9BB5-58F51402FEB2`.
- **Semáforo de RAM** antes de qualquer build: `while [ "$(pgrep -x xcodebuild | wc -l)" -ge 2 ]; do sleep 20; done`.
- Baseline atual: **479/479** testes verdes. Nenhuma frente pode reduzir o total sem justificar no
  commit (teste reescrito conta como substituição, não perda).
- Board: mover/comentar com `--agent <seu nome>`; terminar = **`feito`** (nunca `em_revisao`).

## Estrutura de arquivos

| Arquivo | Responsabilidade | Dono |
|---|---|---|
| `CutuqueApp/AppTheme.swift` | `EnvironmentValues.corDeDestaque` | **Onda 0** |
| `CutuqueApp/CutuqueApp.swift` | injeta o valor ao lado do `.tint` | **Onda 0** |
| `CutuqueApp/NavigationState.swift` | `SegmentoDeChrome` + registro por aba | **Onda 0** |
| `CutuqueApp/ChromeDaAba.swift` *(novo)* | a faixa: seletor + ⤡ | **Onda 0** |
| `CutuqueApp/RootSplitView.swift` | costura da chrome + limpeza ao fechar aba | **Onda 0** |
| `CutuqueApp/SeletorDeIconeDeMaquina.swift` *(novo)* | grade de ícones reusável | **Onda 0** |
| `CutuqueApp/MachineInfoSheet.swift` | consome a grade extraída; cor | **Onda 0** |
| `CutuqueApp/OpenTabs.swift` + `TabBar.swift` | modelo de navegador + cores da barra | **F1** |
| `BoardView`, `QuestionCardView`, `SessionDetailView`, `TerminalMirrorView`, `TerminalThemePicker`, `FolderPickerView`, `NewSessionView`, `MachineListView`, `HistoryView`, `Models.swift` | varredura de cor | **F2** |
| `CutuqueApp/SessionDetailPane.swift` + `SessionDetailPaneLogic.swift` | publica segmentos, sai da toolbar | **F3** |
| `CutuqueApp/MachineDetailView.swift` | publica segmentos, botão de info na chrome | **F4** |
| `CutuqueApp/NewMachineView.swift` | ícone/tema ao editar | **F5** |
| `CutuqueApp/SessionListView.swift` + `MergedorDeVivas.swift` *(novo)* | carga paralela e incremental | **F6** |

## Git

Branch base: `abas-navegador-base` (sai de `master`, HEAD `779f1f2`). A onda 0 commita nela. Cada
frente sai de `abas-navegador-base` num worktree próprio
(`git worktree add cutuque-worktrees/<frente> -b <frente> abas-navegador-base`), commita na sua branch e
para. O merge e a integração são do orquestrador.

---

## Onda 0: vocabulário compartilhado (orquestrador, antes de tudo)

**Arquivos:**
- Modificar: `app/CutuqueApp/AppTheme.swift`, `app/CutuqueApp/CutuqueApp.swift:51`,
  `app/CutuqueApp/NavigationState.swift`, `app/CutuqueApp/RootSplitView.swift:376-421`,
  `app/CutuqueApp/MachineInfoSheet.swift:125-190`
- Criar: `app/CutuqueApp/ChromeDaAba.swift`, `app/CutuqueApp/SeletorDeIconeDeMaquina.swift`
- Testar: `app/CutuqueAppTests/ChromeDaAbaTests.swift` *(novo)*

**Interfaces produzidas** (é isto que as seis frentes consomem):

```swift
// AppTheme.swift
extension EnvironmentValues { var corDeDestaque: Color { get set } }

// NavigationState.swift
struct SegmentoDeChrome: Identifiable, Equatable, Hashable {
    let id: String          // "chat" | "terminal" | "info" | "arquivos"
    let titulo: String
    let simbolo: String
}
@MainActor final class NavigationState {
    func definirSegmentos(_ segmentos: [SegmentoDeChrome], de chave: ChaveDeAba)
    func segmentos(de chave: ChaveDeAba?) -> [SegmentoDeChrome]
    func escolher(_ id: String, de chave: ChaveDeAba)
    func escolha(de chave: ChaveDeAba?) -> String?
    func limparChrome(de chave: ChaveDeAba)
}

// ChromeDaAba.swift
struct ChromeDaAba: View { let chave: ChaveDeAba }

// SeletorDeIconeDeMaquina.swift
struct SeletorDeIconeDeMaquina: View {
    let so: String                       // SO detectado, para o cartão "Automático"
    let escolhido: String                // "" = automático
    let habilitado: Bool
    let aoEscolher: (String) -> Void
}
```

- [ ] **Passo 1: teste falhando do registro de chrome**

`app/CutuqueAppTests/ChromeDaAbaTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

@MainActor
final class ChromeDaAbaTests: XCTestCase {
    private let a = ChaveDeAba(tipo: .sessao, alvo: "mike")
    private let b = ChaveDeAba(tipo: .maquina, machine: "macmini", alvo: "macmini")

    private let tresDaSessao = [
        SegmentoDeChrome(id: "chat", titulo: "Chat", simbolo: "bubble.left"),
        SegmentoDeChrome(id: "terminal", titulo: "Terminal", simbolo: "apple.terminal"),
        SegmentoDeChrome(id: "info", titulo: "Info", simbolo: "info.circle"),
    ]

    func testSegmentosFicamPorAba() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: a)
        XCTAssertEqual(nav.segmentos(de: a).map(\.id), ["chat", "terminal", "info"])
        // O painel da máquina não herda os segmentos da sessão: por decisão #19
        // os dois ficam MONTADOS ao mesmo tempo, e era exatamente essa mistura
        // que escondia o seletor na toolbar (13/08/2026).
        XCTAssertTrue(nav.segmentos(de: b).isEmpty)
    }

    func testEscolhaNaoVazaEntreAbas() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: a)
        nav.escolher("terminal", de: a)
        XCTAssertEqual(nav.escolha(de: a), "terminal")
        XCTAssertNil(nav.escolha(de: b))
    }

    func testSemAbaNaoTemSegmentoNemEscolha() {
        let nav = NavigationState()
        XCTAssertTrue(nav.segmentos(de: nil).isEmpty)
        XCTAssertNil(nav.escolha(de: nil))
    }

    func testLimparRemoveSegmentosEEscolha() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: a)
        nav.escolher("info", de: a)
        nav.limparChrome(de: a)
        XCTAssertTrue(nav.segmentos(de: a).isEmpty)
        XCTAssertNil(nav.escolha(de: a))
    }

    /// Escrever o MESMO valor não pode publicar mudança: `definirSegmentos` é
    /// chamada de `.onChange`/`.task` dos painéis, que rodam a cada
    /// recomposição — publicar igual é laço de atualização de view.
    func testDefinirIgualNaoPublica() {
        let nav = NavigationState()
        var avisos = 0
        let cancelavel = nav.objectWillChange.sink { _ in avisos += 1 }
        nav.definirSegmentos(tresDaSessao, de: a)
        let depoisDaPrimeira = avisos
        nav.definirSegmentos(tresDaSessao, de: a)
        XCTAssertEqual(avisos, depoisDaPrimeira, "definirSegmentos idempotente não pode publicar")
        cancelavel.cancel()
    }
}
```

- [ ] **Passo 2: rodar e ver falhar**

`xcodebuild test ... -only-testing:CutuqueAppTests/ChromeDaAbaTests` → FALHA com
"cannot find 'SegmentoDeChrome' in scope".

- [ ] **Passo 3: `SegmentoDeChrome` + registro em `NavigationState.swift`**

Junto de `modosPorAba` (`:152`), com a razão escrita:

```swift
/// Um segmento do seletor da `ChromeDaAba`. Dado puro: quem sabe desenhar é a
/// chrome, quem sabe o que existe é o painel.
struct SegmentoDeChrome: Identifiable, Equatable, Hashable {
    let id: String
    let titulo: String
    let simbolo: String
}

/// O que a chrome mostra, POR ABA.
///
/// [13/08/2026] Existe porque o seletor morava em `ToolbarItem(placement: .principal)`
/// dentro de cada painel — e, pela decisão #19, N painéis ficam montados para sempre
/// no `ZStack` do iPad. N painéis contribuindo itens para a MESMA navigation bar faz o
/// SwiftUI esconder quase todos: era a causa de "não ta aparecendo o terminal / info
/// embaixo da aba". A chrome é desenhada UMA vez pelo pai, e o painel só declara aqui
/// o que ele tem.
///
/// Registro é dado puro de propósito — nada de closure guardada aqui (ciclo de
/// retenção com o próprio objeto) e nada de `PreferenceKey` (que combinaria os N
/// painéis montados justamente como a toolbar combinava).
@Published private(set) var segmentosDeChrome: [ChaveDeAba: [SegmentoDeChrome]] = [:]
@Published private(set) var escolhaDeChrome: [ChaveDeAba: String] = [:]

func definirSegmentos(_ segmentos: [SegmentoDeChrome], de chave: ChaveDeAba) {
    // Idempotente: os painéis chamam isto de `.onChange`/`.task`, e publicar
    // valor igual é laço de atualização de view.
    guard segmentosDeChrome[chave] != segmentos else { return }
    segmentosDeChrome[chave] = segmentos
}

func segmentos(de chave: ChaveDeAba?) -> [SegmentoDeChrome] {
    guard let chave else { return [] }
    return segmentosDeChrome[chave] ?? []
}

func escolher(_ id: String, de chave: ChaveDeAba) {
    guard escolhaDeChrome[chave] != id else { return }
    escolhaDeChrome[chave] = id
}

func escolha(de chave: ChaveDeAba?) -> String? {
    guard let chave else { return nil }
    return escolhaDeChrome[chave]
}

/// Chamada quando a aba fecha (o pai diffa as chaves). Sem isto o registro cresce
/// para sempre e uma aba reaberta acha segmento velho.
func limparChrome(de chave: ChaveDeAba) {
    segmentosDeChrome[chave] = nil
    escolhaDeChrome[chave] = nil
}
```

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: `corDeDestaque` em `AppTheme.swift` e injeção na raiz**

```swift
private struct CorDeDestaqueKey: EnvironmentKey {
    static let defaultValue = AppAccent.blue.color
}

extension EnvironmentValues {
    /// A cor escolhida em Preferências, como `Color` de verdade.
    ///
    /// [13/08/2026] `Color.accentColor` NÃO serve e foi a causa de "mesmo eu
    /// trocando a cor, alguns lugares fica com cor padrao": ele resolve do
    /// catálogo de assets (que aqui nem tem `AccentColor.colorset`) ou do
    /// sistema, e IGNORA o `.tint()` da raiz. O `.tint` continua existindo para
    /// pintar controle nativo; este valor é para quem precisa da cor como
    /// valor (`.opacity`, `.gradient`, parâmetro `Color`).
    var corDeDestaque: Color {
        get { self[CorDeDestaqueKey.self] }
        set { self[CorDeDestaqueKey.self] = newValue }
    }
}
```

`CutuqueApp.swift:51` passa a:

```swift
let cor = (AppAccent(rawValue: accentRaw) ?? .blue).color
// ... .tint(cor).environment(\.corDeDestaque, cor)
```

- [ ] **Passo 6: `ChromeDaAba.swift`**

```swift
import SwiftUI

/// A faixa embaixo da barra de abas: seletor de painel da aba escolhida + ⤡.
///
/// [13/08/2026, decisão da Vanessa] Uma barra para TODAS as abas, em vez de cada
/// painel publicar na toolbar. Dois motivos: com N painéis montados (decisão #19)
/// a toolbar era disputada e escondia o seletor; e Board/arquivado nunca tiveram
/// tela cheia porque nenhum deles publicava o ⤡. A faixa tem altura fixa mesmo sem
/// segmento: a posição do ⤡ não muda ao trocar de aba.
///
/// O ⤡ e o ⌘⌃F são declarados AQUI e em nenhum outro lugar. Antes, cada painel
/// montado declarava o mesmo atalho — N registros do mesmo ⌘⌃F.
struct ChromeDaAba: View {
    let chave: ChaveDeAba

    @EnvironmentObject private var nav: NavigationState

    var body: some View {
        let segmentos = nav.segmentos(de: chave)
        return HStack(spacing: 8) {
            if !segmentos.isEmpty { seletor(segmentos) }
            Spacer(minLength: 0)
            botaoExpandir
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func seletor(_ segmentos: [SegmentoDeChrome]) -> some View {
        // O GET cai no primeiro segmento quando não há escolha guardada: picker
        // segmentado sem seleção casada fica com NENHUM segmento marcado.
        let atual = Binding<String>(
            get: { nav.escolha(de: chave) ?? segmentos.first?.id ?? "" },
            set: { nav.escolher($0, de: chave) }
        )
        return Picker("Painel", selection: atual) {
            ForEach(segmentos) { s in
                Text(s.titulo).tag(s.id)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var botaoExpandir: some View {
        let expandido = nav.columnVisibility == .detailOnly
        return Button {
            withAnimation(.columnToggle) { nav.toggleColumns() }
        } label: {
            Image(systemName: expandido
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(expandido ? "Recolher para três colunas" : "Expandir o painel")
    }
}
```

- [ ] **Passo 7: costurar em `RootSplitView.abasDetail` (:376-421)**

```swift
VStack(spacing: 0) {
    if !tabsStore.tabs.abas.isEmpty { TabBar(store: tabsStore) }
    if let selecionada = tabsStore.tabs.selecionada {
        ChromeDaAba(chave: selecionada)
    }
    ZStack { /* … inalterado … */ }
}
// A aba fechou: some com o registro dela. O diff mora aqui porque é o pai que
// conhece o antes e o depois; a TabBar só manda fechar.
.onChange(of: tabsStore.tabs.abas.map(\.chave)) { antes, agora in
    for chave in Set(antes).subtracting(agora) { nav.limparChrome(de: chave) }
}
```

- [ ] **Passo 8: extrair `SeletorDeIconeDeMaquina.swift` de `MachineInfoSheet`**

Move `secaoIcone` (:125-129) e `cartaoIcone` (:166-190) para o componente, trocando os três
`Color.accentColor` por `@Environment(\.corDeDestaque)`. `MachineInfoSheet.secaoIcone` passa a:

```swift
@ViewBuilder private var secaoIcone: some View {
    Section {
        SeletorDeIconeDeMaquina(so: so, escolhido: icone, habilitado: machine.isEditable) { id in
            aplicar(tema: tema, icone: id)
        }
    } header: {
        Text("Ícone")
    } footer: {
        Text("Automático usa o sistema detectado.")
    }
}
```

- [ ] **Passo 9: build + suíte completa; commit**

```bash
git add app/CutuqueApp/AppTheme.swift app/CutuqueApp/CutuqueApp.swift \
        app/CutuqueApp/NavigationState.swift app/CutuqueApp/ChromeDaAba.swift \
        app/CutuqueApp/RootSplitView.swift app/CutuqueApp/SeletorDeIconeDeMaquina.swift \
        app/CutuqueApp/MachineInfoSheet.swift app/CutuqueAppTests/ChromeDaAbaTests.swift
git commit -m "feat(abas): chrome única por aba, cor de destaque de ambiente e grade de ícones reusável"
```

**Estado após a onda 0:** a chrome aparece com o ⤡ funcionando em toda aba (item 3 do Board já
fechado), e nenhum painel publica segmento ainda — o seletor fica vazio até F3/F4.

---

## F1: abas de navegador e cores da barra (itens 1 e 2a)

**Arquivos:**
- Modificar: `app/CutuqueApp/OpenTabs.swift:67-69,99-120,201-215`, `app/CutuqueApp/TabBar.swift:54,79,91-96`
- Testar: `app/CutuqueAppTests/OpenTabsTests.swift`

**Interfaces:**
- Consome: `EnvironmentValues.corDeDestaque` (onda 0).
- Produz: `OpenTabs.abrir(chave:titulo:conteudo:)` — **sem** o parâmetro `estilo`. `AbaAberta` deixa de
  ter o campo `estilo`. `EstiloDeAba` deixa de existir.

- [ ] **Passo 1: reescrever o teste que trancava a decisão antiga**

Em `OpenTabsTests.swift`, o teste que hoje afirma a substituição (`:15-16`) vira o oposto. **Não
delete o teste** — ele documenta a decisão revogada; reescreva com a razão nova:

```swift
/// [Reescrito em 13/08/2026] Este teste afirmava o contrário: a aba de passagem
/// (modelo VS Code) era substituída pela próxima abertura. A Vanessa pediu modelo
/// de NAVEGADOR — "ao invés de funcionar como um navegador que vai abrindo uma ao
/// lado da outra, so se fixar funciona" —, e `EstiloDeAba` foi removido inteiro.
func testAbrirDuasSessoesMantemAsDuasAbas() {
    var t = OpenTabs()
    t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
    t.abrir(chave: b, titulo: "aux", conteudo: .pendente)
    XCTAssertEqual(t.abas.map(\.chave), [a, b])
    XCTAssertEqual(t.selecionada, b, "a recém-aberta fica em foco")
}

/// Fixar deixou de ser o único jeito de acumular aba; segue sendo o que protege
/// de "fechar outras" e o que garante vaga entre as vivas (teto de 6).
func testFixarSegueProtegendoDeFecharOutras() {
    var t = OpenTabs()
    t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
    t.fixar(a)
    t.abrir(chave: b, titulo: "aux", conteudo: .pendente)
    t.fecharOutras(b)
    XCTAssertEqual(Set(t.abas.map(\.chave)), Set([a, b]))
}
```

Todos os outros testes do arquivo perdem o argumento `estilo: .normal` (é mecânico: ele era o jeito
de pedir o comportamento que agora é o único).

- [ ] **Passo 2: rodar e ver falhar**

`-only-testing:CutuqueAppTests/OpenTabsTests` → FALHA (compilação: `estilo` não existe mais nos testes
reescritos, e o teste novo falha porque a aba `a` é removida).

- [ ] **Passo 3: remover `EstiloDeAba` de `OpenTabs.swift`**

Apagar o enum (:67-69) e o campo `estilo` de `AbaAberta`. Em `abrir`, remover o parâmetro, a linha
`abas[i].estilo = .normal` e o bloco de remoção (:114-116). O comentário do reaproveitamento (:104-106)
perde a palavra "PROMOVE" e ganha a razão nova:

```swift
/// [13/08/2026] Modelo de navegador: abrir NUNCA substitui aba nenhuma. Antes
/// existia a "aba de passagem" (preview do VS Code), única, que a próxima
/// abertura tomava — decisão minha de 12/08, revogada pela Vanessa: "ao invés de
/// funcionar como um navegador que vai abrindo uma ao lado da outra, so se fixar
/// funciona". O teto de `maxVivas` continua sendo o que segura o custo: abas
/// acumulam na barra e as menos recentes DORMEM (ver `vivas`).
mutating func abrir(chave: ChaveDeAba, titulo: String, conteudo: TabConteudo) {
```

Em `reconciliar`/`paraPersistir` (:201-215), remover `estilo: .normal` da construção.

- [ ] **Passo 4: rodar OpenTabsTests e ver passar**

- [ ] **Passo 5: cores da barra em `TabBar.swift`**

Remover `.italic(aba.estilo == .passagem)` (:79) — junto do comentário do VS Code, que deixou de ser
verdade. A faixa e a aba escolhida passam a:

```swift
@Environment(\.corDeDestaque) private var destaque

// no corpo da barra, em vez de `.background(.bar)`:
.background(Color(.secondarySystemBackground))

// na aba, em vez de AnyShapeStyle(.selection) e do foregroundStyle atual:
.background(escolhida ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6))
// …
.foregroundStyle(escolhida ? destaque : Color.secondary)
```

Comentário no ponto da decisão:

```swift
// [13/08/2026] Comportamento de navegador, como a Vanessa pediu: a aba escolhida
// é a FOLHA DA FRENTE — fundo branco no claro, quase-preto no escuro
// (`.systemBackground`) — e o nome e o ✕ ficam na cor de destaque dela. Antes a
// faixa era `.background(.bar)` e a aba escolhida `.selection`: material e cinza
// de sistema, que não veem a preferência de cor ("a cor da aba ta um cinza
// estranho"). `.orange` do aviso de sessão morta NÃO muda: é semântico.
```

O ✕ herda o `foregroundStyle` do botão pai — nada a fazer nele. O `pin.fill` e o triângulo laranja
ficam como estão.

- [ ] **Passo 6: suíte completa + commit**

```bash
git add app/CutuqueApp/OpenTabs.swift app/CutuqueApp/TabBar.swift app/CutuqueAppTests/OpenTabsTests.swift
git commit -m "feat(abas): abrir ao lado como navegador e barra com a cor de destaque"
```

---

## F2: varredura de cor no resto do app (item 2b)

**Arquivos (todos "modificar"):** `BoardView.swift:498,501,504,577`,
`QuestionCardView.swift:236,303,342,345,379,408,426,450`, `SessionDetailView.swift:771,1007,1042`,
`TerminalMirrorView.swift:622`, `TerminalThemePicker.swift:46,54`, `FolderPickerView.swift:48`,
`NewSessionView.swift:219,228`, `MachineListView.swift:131`, `HistoryView.swift:173`,
`Models.swift:46`

**Interfaces:**
- Consome: `EnvironmentValues.corDeDestaque` (onda 0).
- Produz: nada de novo. É substituição de token.

**A regra, sem exceção improvisada:** troque por `@Environment(\.corDeDestaque) private var destaque`
o que é **ação primária, seleção ou identidade**. Mantenha literal o que é semântico. Casos deste
conjunto, decididos:

| Ponto | O que fazer |
|---|---|
| `Color.accentColor` (todos os 21 pontos destes arquivos) | → `destaque` |
| `QuestionCardView.swift:303` `.tint(isLastQuestion ? .green : Color.accentColor)` | → `.tint(isLastQuestion ? .green : destaque)` — o verde do último passo **fica** |
| `SessionDetailView.swift:771` `isRunning ? Color.red : (canSend ? Color.accentColor : .gray…)` | só o meio vira `destaque`; vermelho e cinza ficam |
| `FolderPickerView.swift:48` `dir.isHidden ? .secondary : Color.blue` | → `destaque` |
| `NewSessionView.swift:219,228` `.foregroundStyle(.blue)` | → `destaque` |
| `MachineListView.swift:131` `.tint(.blue)` | → `.tint(destaque)` |
| `HistoryView.swift:173` `case "user": return .blue` | → cor de destaque (identidade dela na conversa) |
| `Models.swift:46` `case .running: return .blue` | ver passo 3 — **não** dá para ler ambiente aqui |
| `TerminalMirrorView.swift:616`, `SessionDetailView.swift:759`, `DiscoverSessionsView.swift:302` (`.tint(.white)`) | **não tocar**: contraste sobre fundo colorido |
| `BoardView.swift:794` `.tint(.red)`, `SessionDetailView.swift:557/566`, `SessionListView.swift:1018` (`.green`/`.red`) | **não tocar**: semânticos |

- [ ] **Passo 1: teste falhando do único ponto testável — o status `.running`**

`Models.swift:46` é uma computed property de modelo: não tem ambiente. `SessionListView.swift:923` já
resolve isso na view (`s == .running ? accentColor : s.color`). Torne isso explícito e testável,
em `app/CutuqueAppTests/CorDeStatusTests.swift` *(novo)*:

```swift
import SwiftUI
import XCTest
@testable import CutuqueApp

final class CorDeStatusTests: XCTestCase {
    /// `.running` é o único status que segue a preferência: ele não é semântico
    /// (não é erro, não é sucesso, não é aviso) — é "a coisa está andando", que é
    /// o papel de destaque do app. Os outros três são semânticos e NÃO mudam.
    func testSoORunningSegueADestaque() {
        let cor = Color.purple
        XCTAssertEqual(CorDeStatus.para(.running, destaque: cor), cor)
        XCTAssertEqual(CorDeStatus.para(.error, destaque: cor), SessionStatus.error.color)
        XCTAssertEqual(CorDeStatus.para(.needsYou, destaque: cor), SessionStatus.needsYou.color)
    }
}
```

> Confira os nomes reais dos casos de `SessionStatus` em `Models.swift` antes de escrever o teste — use
> os que existirem, sem inventar caso.

- [ ] **Passo 2: rodar e ver falhar** — "cannot find 'CorDeStatus' in scope".

- [ ] **Passo 3: `CorDeStatus` em `Models.swift`, junto do `color` atual**

```swift
/// A cor de um status na tela. Separada de `SessionStatus.color` porque a cor de
/// destaque vem do AMBIENTE (`\.corDeDestaque`) e modelo não lê ambiente.
/// `SessionListView` já fazia isto à mão (`s == .running ? accentColor : s.color`);
/// aqui vira um lugar só, testável. (13/08/2026)
enum CorDeStatus {
    static func para(_ status: SessionStatus, destaque: Color) -> Color {
        status == .running ? destaque : status.color
    }
}
```

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: varredura arquivo por arquivo**

Em cada arquivo da lista: adicionar `@Environment(\.corDeDestaque) private var destaque` na view (uma
vez por `struct`, incluindo as views auxiliares privadas do arquivo) e trocar os pontos da tabela. Onde
o `Color.accentColor` estava dentro de `static`/função sem acesso a ambiente, passe `destaque` como
parâmetro em vez de mover a decisão para o modelo.

- [ ] **Passo 6: prova objetiva da varredura**

```bash
grep -rn "Color.accentColor" app/CutuqueApp | wc -l    # deve ser 0
grep -rn "\.blue\b" app/CutuqueApp | grep -v "AppTheme.swift\|RealceDeSintaxe.swift\|AppAccent"
# só devem sobrar os defaults de @AppStorage (AppAccent.blue.rawValue)
```

- [ ] **Passo 7: suíte completa + commit** (`git add` com os 10 caminhos + o teste novo)

---

## F3: a aba de sessão publica seus segmentos (item 5)

**Arquivos:**
- Modificar: `app/CutuqueApp/SessionDetailPaneLogic.swift`,
  `app/CutuqueApp/SessionDetailPane.swift:153-161,183-246`
- Testar: `app/CutuqueAppTests/SessionDetailPaneLogicTests.swift`

**Interfaces:**
- Consome: `SegmentoDeChrome`, `NavigationState.definirSegmentos/escolher/escolha` (onda 0).
- Produz: `SessionDetailPaneLogic.segmentosDeChrome(hasChat:hasTerminal:hasInfo:) -> [SegmentoDeChrome]`,
  com ids **iguais a `PaneMode.rawValue`** (`"chat"`, `"terminal"`, `"info"`) — é isso que faz a ponte
  `PaneMode(rawValue:)` ser trivial.

- [ ] **Passo 1: teste falhando dos segmentos**

Em `SessionDetailPaneLogicTests.swift`, ao lado dos testes de `selectorSegments`:

```swift
/// Os ids são os `rawValue` de `PaneMode` de propósito: a chrome devolve um
/// String e a ponte no painel é `PaneMode(rawValue:)`. Se divergirem, o toque no
/// seletor não muda painel nenhum — silenciosamente.
func testIdsDosSegmentosSaoOsRawValuesDoPaneMode() {
    let s = SessionDetailPaneLogic.segmentosDeChrome(hasChat: true, hasTerminal: true, hasInfo: true)
    XCTAssertEqual(s.map(\.id), [PaneMode.chat.rawValue, PaneMode.terminal.rawValue, PaneMode.info.rawValue])
    XCTAssertEqual(s.map(\.titulo), ["Chat", "Terminal", "Info"])
}

func testSessaoSoComChatNaoGeraSeletor() {
    let s = SessionDetailPaneLogic.segmentosDeChrome(hasChat: true, hasTerminal: false, hasInfo: false)
    XCTAssertTrue(s.isEmpty, "um segmento só não é escolha — a chrome mostra só o ⤡")
}

func testEntradaAoVivoTemTerminalEInfoSemChat() {
    let s = SessionDetailPaneLogic.segmentosDeChrome(hasChat: false, hasTerminal: true, hasInfo: true)
    XCTAssertEqual(s.map(\.id), ["terminal", "info"])
}
```

> Antes de escrever, leia `selectorSegments` para reproduzir **exatamente** a regra existente de quando
> a lista é vazia (hoje ela decide isso e `SessionDetailPane:154` só checa `isEmpty`). A regra não muda
> nesta frente — só o tipo de retorno.

- [ ] **Passo 2: rodar e ver falhar**

- [ ] **Passo 3: `segmentosDeChrome` em `SessionDetailPaneLogic.swift`**

Nova função ao lado de `selectorSegments`, com os símbolos: `chat` → `bubble.left`, `terminal` →
`apple.terminal`, `info` → `info.circle`. Mantenha `selectorSegments` se `modoValido` a usa; se ficar
sem chamador, remova junto com seus testes reescritos (não deixe função morta).

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: o painel publica e obedece, em vez de desenhar**

Em `SessionDetailPane.swift`, o `.toolbar` (:153-161) perde o `.principal` e o `expandButton`. O
`closeTerminalButton` **fica na toolbar**, mas ganha a guarda que faltava: só a aba **em foco** publica.
Sem ela, duas abas ao vivo em modo terminal publicam dois ✕ no mesmo `.topBarTrailing` — a mesma
disputa, só num placement diferente.

```swift
// [13/08/2026] Este painel NÃO desenha mais seletor nem ⤡: quem desenha é a
// `ChromeDaAba`, uma vez, para a aba selecionada. Com N painéis montados
// (decisão #19) N `ToolbarItem(placement: .principal)` disputavam a mesma
// navigation bar e o SwiftUI escondia quase todos — era a causa de "não ta
// aparecendo o terminal / info embaixo da aba".
//
// O ✕ de fechar o terminal continua aqui, e `paneState == .ativo` é a guarda que
// faltava: ele é o "esta aba está em foco" (ver o comentário de :115). Duas abas
// ao vivo em modo terminal publicariam dois ✕ no mesmo lugar.
.toolbar {
    if liveEntry != nil, showsTerminal, paneState == .ativo {
        ToolbarItem(placement: .topBarTrailing) { closeTerminalButton }
    }
}
// Declara o que esta aba tem, e mantém a declaração em dia quando a sessão ganha
// terminal ou entrada ao vivo.
.task(id: assinaturaDosSegmentos) {
    nav.definirSegmentos(
        SessionDetailPaneLogic.segmentosDeChrome(
            hasChat: session != nil, hasTerminal: terminal != nil, hasInfo: liveEntry != nil),
        de: chave)
    nav.escolher(modo.rawValue, de: chave)   // reflete o modo já guardado
}
// A chrome escreveu: aplica no guardado desta aba. Uma direção só.
.onChange(of: nav.escolha(de: chave)) { _, novo in
    guard let novo, let modo = PaneMode(rawValue: novo) else { return }
    nav.definirPaneMode(modo, de: chave)
}
```

Com `private var assinaturaDosSegmentos: String { "\(session != nil)-\(terminal != nil)-\(liveEntry != nil)" }`.

Remover `expandButton` (:235-246) e o `selector`/`paneModeBinding` que ficarem sem chamador — o ⤡ e o
⌘⌃F agora existem **só** na `ChromeDaAba`. O `closeTerminalButton` fica onde está, com o comentário
dele intacto.

- [ ] **Passo 6: suíte completa + commit**

---

## F4: a aba de máquina na chrome (itens 3 e 4a)

**Arquivos:**
- Modificar: `app/CutuqueApp/MachineDetailView.swift:101-104,166-174,236-246`
- Testar: `app/CutuqueAppTests/MachineAppearanceTests.swift` (arquivo existente)

**Interfaces:**
- Consome: `SegmentoDeChrome`, registro da onda 0, `SeletorDeIconeDeMaquina` (não usa aqui, é da F5).
- Produz: segmentos com ids **`MachinePane.rawValue`** (`"terminal"`, `"files"`).

- [ ] **Passo 1: teste falhando da ponte de ids**

```swift
/// Ids de `MachinePane`, não de `PaneMode`: as duas abas usam a mesma chrome, e o
/// registro é por CHAVE DE ABA — "terminal" numa não é "terminal" na outra. A
/// ponte de cada painel converte com o SEU enum.
@MainActor
func testChromeDaMaquinaUsaOsIdsDeMachinePane() {
    let nav = NavigationState()
    let chave = ChaveDeAba(tipo: .maquina, machine: "macmini", alvo: "macmini")
    nav.definirSegmentos(MachineDetailView.segmentosDeChrome(), de: chave)
    XCTAssertEqual(nav.segmentos(de: chave).map(\.id),
                   [MachinePane.terminal.rawValue, MachinePane.files.rawValue])
}
```

- [ ] **Passo 2: rodar e ver falhar**

- [ ] **Passo 3: `static func segmentosDeChrome()` em `MachineDetailView`**

```swift
/// Os dois painéis da máquina, para a `ChromeDaAba`. `static` para ter teste sem
/// hospedar View — a máquina não muda quais painéis existem.
static func segmentosDeChrome() -> [SegmentoDeChrome] {
    MachinePane.allCases.map { SegmentoDeChrome(id: $0.rawValue, titulo: $0.label, simbolo: $0.symbol) }
}
```

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: sair da toolbar, publicar na chrome, e o botão de info sobreviver**

No `.toolbar` (:101-104): remover o `ToolbarItem(placement: .principal) { seletor }` e apagar o
`seletor` (:236-246) — ele **migra** para a chrome, é a decisão dela ("o seletor migra em vez de
empilhar uma segunda faixa"). O botão que abre a `MachineInfoSheet` (:166-172) **fica** em
`.topBarTrailing`, agora sem disputar com o `.principal`; comente por quê:

```swift
// [13/08/2026] O seletor terminal/arquivos saiu daqui para a `ChromeDaAba`. Este
// botão de Informações ficou: é ele que leva ao ícone e ao tema da máquina, e era
// um dos itens que o SwiftUI escondia quando N painéis montados disputavam esta
// toolbar ("a parte de personalizar a maquina não deixa escolher as coisas do hub").
```

Publicar e obedecer, com a persistência da máquina (`@AppStorage paneRaw`) intocada:

```swift
.task {
    nav.definirSegmentos(Self.segmentosDeChrome(), de: chaveDaAba)
    nav.escolher(paneRaw, de: chaveDaAba)
}
.onChange(of: nav.escolha(de: chaveDaAba)) { _, novo in
    guard let novo, MachinePane(rawValue: novo) != nil else { return }
    paneRaw = novo
}
```

> `chaveDaAba` = `ChaveDeAba(tipo: .maquina, machine: machine.name, alvo: machine.name)`. Confirme a
> forma exata com que `RootSplitView:200` cria a chave da máquina e use **a mesma** — chave diferente
> significa registro que a chrome nunca lê.

- [ ] **Passo 6: suíte completa + commit**

---

## F5: ícone e tema ao editar máquina (item 4b)

**Arquivos:**
- Modificar: `app/CutuqueApp/NewMachineView.swift:129-133,307-315,485-500`
- Criar: `app/CutuqueAppTests/AparenciaAoEditarTests.swift` (arquivo novo — `MachineAppearanceTests.swift`
  é da F4 nesta leva, não mexa nele)

**Interfaces:**
- Consome: `SeletorDeIconeDeMaquina` (onda 0), `APIClient.setAppearance(name:theme:icon:)`.
- Produz: `NewMachineView.Aparencia` — decisão pura de o que enviar ao salvar.

- [ ] **Passo 1: teste falhando da decisão de envio**

```swift
import XCTest
@testable import CutuqueApp

/// O `PATCH` desta tela manda `theme: ""` e "" significa MANTÉM — ele não sabe
/// dizer "volta ao padrão". Era a razão de aparência não existir ao editar
/// (comentário de 12/08). A razão continua verdadeira: o que muda é que a tela
/// passa a chamar TAMBÉM o `PUT /appearance`, que sabe. (13/08/2026)
final class AparenciaAoEditarTests: XCTestCase {
    func testNaoChamaAppearanceQuandoNadaMudou() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "dracula", iconeEscolhido: "server")
        XCTAssertNil(d)
    }

    func testVoltarAoPadraoEnviaVazio() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "", iconeEscolhido: "")
        XCTAssertEqual(d?.tema, "")
        XCTAssertEqual(d?.icone, "")
    }

    /// O PUT leva os DOIS campos sempre: mandar só o que mudou apagaria o outro
    /// (vazio é escolha no `/appearance`, não "mantém").
    func testMudarSoOIconeAindaEnviaOTemaAtual() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "",
                                                temaEscolhido: "dracula", iconeEscolhido: "laptop")
        XCTAssertEqual(d?.tema, "dracula")
        XCTAssertEqual(d?.icone, "laptop")
    }
}
```

- [ ] **Passo 2: rodar e ver falhar**

- [ ] **Passo 3: `Aparencia.decidir` em `NewMachineView`**

```swift
extension NewMachineView {
    /// O que mandar para `PUT /machines/{n}/appearance` ao salvar a edição, ou
    /// `nil` se nada mudou (não gastar pedido nem sobrescrever com igual).
    struct Aparencia: Equatable {
        let tema: String
        let icone: String

        static func decidir(temaAtual: String, iconeAtual: String,
                            temaEscolhido: String, iconeEscolhido: String) -> Aparencia? {
            guard temaEscolhido != temaAtual || iconeEscolhido != iconeAtual else { return nil }
            return Aparencia(tema: temaEscolhido, icone: iconeEscolhido)
        }
    }
}
```

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: a seção aparece ao editar e o salvar chama o endpoint certo**

`:133` deixa de esconder e passa a escolher a seção certa:

```swift
// [13/08/2026] Editando, aparência agora vem — pedido da Vanessa ("a parte de
// personalizar a maquina não deixa escolher as coisas do hub tipo icone, tema e
// tal"), e ela pediu nos DOIS lugares (aqui e na sheet Informações). O `PATCH`
// continua mandando `theme: ""` (= mantém) porque continua não sabendo expressar
// "volta ao padrão": quem leva aparência é o `PUT /appearance`, chamado no salvar.
// Cadastrando, segue só o tema pelo POST — máquina que ainda não existe não tem
// `/appearance` para chamar (era a assimetria que o comentário antigo registrava).
if modo.editando { secaoAparencia } else { secaoTema }
```

```swift
@ViewBuilder private var secaoAparencia: some View {
    Section {
        SeletorDeIconeDeMaquina(so: soDetectado, escolhido: icone, habilitado: !camposTravados) {
            icone = $0
        }
    } header: {
        Text("Ícone")
    }
    Section {
        TerminalThemePicker(selection: $tema)
            .frame(minHeight: 220) // o picker é um ScrollView sem altura própria
    } header: {
        Text("Tema do terminal")
    } footer: {
        Text("Vale só para esta máquina, e o terminal aberto muda de cor na hora.")
    }
    .disabled(camposTravados)
}
```

Precisa de `@State private var icone: String`, inicializado no `init` a partir da máquina do
`modo` (como `tema` já é). No fluxo de salvar (`:485-500`), **depois** do `updateMachine`:

```swift
// O PATCH acima não leva aparência (`theme: ""` = mantém). Quem leva é este PUT,
// e só quando algo mudou de fato. (13/08/2026)
if let alvo = Aparencia.decidir(temaAtual: atual.theme, iconeAtual: atual.icon,
                                temaEscolhido: tema, iconeEscolhido: icone) {
    _ = try await api.setAppearance(name: atual.name, theme: alvo.tema, icon: alvo.icone)
}
```

Reescrever o comentário de `:493-494` para dizer que o `theme: ""` do PATCH segue de propósito e que
aparência vai pelo PUT logo abaixo. Confira os nomes reais dos campos de `Machine` (`theme`, `icon`)
antes de usar.

- [ ] **Passo 6: suíte completa + commit**

---

## F6: as sessões ao vivo aparecem em ~1 s (item 6)

**Arquivos:**
- Criar: `app/CutuqueApp/MergedorDeVivas.swift`
- Modificar: `app/CutuqueApp/SessionListView.swift:105,164-214,313,618-624,1131` e a seção "Ao vivo" da
  lista
- Testar: `app/CutuqueAppTests/MergedorDeVivasTests.swift` *(novo)*

**Interfaces:**
- Consome: `EnvironmentValues.corDeDestaque` (onda 0) para o `:1131`.
- Produz: `MergedorDeVivas`.

**Medição que motiva a frente** (contra o hub de produção, 13/08): `/targets` 0,0006 s; `macbook`
1,03 s (7 panes); `macmini` 0,24 s; `windows` **10,016 s** (0 panes, `ConnectTimeout=10` do ssh numa
máquina desligada). Sequencial = **11,28 s** antes de qualquer coisa pintar.

- [ ] **Passo 1: testes falhando do mergedor**

```swift
import XCTest
@testable import CutuqueApp

final class MergedorDeVivasTests: XCTestCase {
    /// `DiscoveredSession` tem init de conveniência com defaults — o mesmo que
    /// `AbasNavegacaoTests:26` e `LivePaneIdentityTests:22` usam.
    private func entrada(_ maquina: String, _ alvo: String) -> LiveEntry {
        LiveEntry(machine: maquina, session: DiscoveredSession(id: alvo, cwd: "/tmp", title: alvo))
    }

    /// O ponto da frente inteira: máquina lenta não segura máquina rápida.
    /// Antes, `refreshLive` só publicava DEPOIS do laço sequencial, então as 7
    /// panes do macbook (1 s) esperavam o windows (10 s de ConnectTimeout).
    func testMaquinaVaziaNaoApagaAOutra() {
        var m = MergedorDeVivas(ordem: ["macbook", "macmini", "windows"])
        _ = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "mike")])
        let depois = m.fundir(maquina: "windows", entradas: [])
        XCTAssertEqual(depois.count, 1)
    }

    /// A regra dos 2 vazios seguidos existia global; virou POR MÁQUINA. Global,
    /// o windows (sempre 0) zeraria o contador de todo mundo.
    func testDoisVaziosSeguidosLimpamSoAquelaMaquina() {
        var m = MergedorDeVivas(ordem: ["macbook", "macmini"])
        _ = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "mike")])
        _ = m.fundir(maquina: "macmini", entradas: [entrada("macmini", "aux")])
        _ = m.fundir(maquina: "macbook", entradas: [])
        XCTAssertEqual(m.entradas.count, 2, "um vazio só não limpa — leitura falha acontece")
        let depois = m.fundir(maquina: "macbook", entradas: [])
        XCTAssertEqual(depois.map(\.machine), ["macmini"])
    }

    /// Ordem estável, senão a lista pula de lugar conforme quem responde primeiro.
    func testOrdemSegueADeTargetsEnaoADeChegada() {
        var m = MergedorDeVivas(ordem: ["macbook", "macmini"])
        _ = m.fundir(maquina: "macmini", entradas: [entrada("macmini", "aux")])
        let depois = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "mike")])
        XCTAssertEqual(depois.map(\.machine), ["macbook", "macmini"])
    }

    func testResponderDeNovoSubstituiEmVezDeDuplicar() {
        var m = MergedorDeVivas(ordem: ["macbook"])
        _ = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "a"), entrada("macbook", "b")])
        let depois = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "a")])
        XCTAssertEqual(depois.count, 1)
    }
}
```

- [ ] **Passo 2: rodar e ver falhar**

- [ ] **Passo 3: `MergedorDeVivas.swift`**

```swift
/// Funde as panes ao vivo máquina por máquina, à medida que cada uma responde.
///
/// [13/08/2026] Existe porque `refreshLive` buscava sequencialmente e só publicava
/// no fim: medido contra produção, 11,28 s até a lista pintar, dos quais 10,016 s
/// eram o `ConnectTimeout=10` do ssh numa máquina desligada. As 7 panes do macbook
/// chegavam em 1 s e esperavam. Sem estado de carregando, isso é
/// indistinguível de "não tem nada rodando" — daí "sempre preciso puxar pra baixo
/// pra dar o refresh".
///
/// A regra de "limpa só depois de 2 leituras vazias seguidas" era GLOBAL e aqui é
/// POR MÁQUINA: global, a máquina desligada (sempre 0) apagaria as vivas das
/// outras a cada passada.
struct MergedorDeVivas {
    static let vaziosParaLimpar = 2

    private var ordem: [String]
    private var porMaquina: [String: [LiveEntry]] = [:]
    private var vazios: [String: Int] = [:]

    init(ordem: [String]) { self.ordem = ordem }

    var entradas: [LiveEntry] { ordem.flatMap { porMaquina[$0] ?? [] } }

    mutating func definirOrdem(_ nova: [String]) {
        ordem = nova
        // Máquina que saiu do /targets não deixa fantasma na lista.
        for chave in porMaquina.keys where !nova.contains(chave) {
            porMaquina[chave] = nil
            vazios[chave] = nil
        }
    }

    mutating func fundir(maquina: String, entradas novas: [LiveEntry]) -> [LiveEntry] {
        if novas.isEmpty {
            let n = (vazios[maquina] ?? 0) + 1
            vazios[maquina] = n
            if n >= Self.vaziosParaLimpar { porMaquina[maquina] = [] }
        } else {
            vazios[maquina] = 0
            porMaquina[maquina] = novas
        }
        if !ordem.contains(maquina) { ordem.append(maquina) }
        return entradas
    }
}
```

- [ ] **Passo 4: rodar e ver passar**

- [ ] **Passo 5: `refreshLive` em paralelo, publicando incremental**

`SessionListView.swift:182`:

```swift
/// [13/08/2026] Paralelo e incremental. Antes: `for machine in machines { await … }`
/// e uma única atribuição no fim. Ver `MergedorDeVivas` para a medição.
func refreshLive(mostrandoCarga: Bool = false) async {
    let machines = (try? await api.targets()).flatMap { $0.isEmpty ? nil : $0 } ?? cachedMachines
    guard !machines.isEmpty else { return }
    cachedMachines = machines
    mergedor.definirOrdem(machines)
    if mostrandoCarga { maquinasPendentes = Set(machines) }

    await withTaskGroup(of: (String, [LiveEntry]).self) { grupo in
        for machine in machines {
            grupo.addTask { [api] in
                let panes = await api.tmuxList(machine: machine)
                return (machine, panes.map { LiveEntry(machine: machine, session: $0) })
            }
        }
        // Cada máquina que responde pinta na hora: o macbook não espera o windows.
        for await (machine, entradas) in grupo {
            liveSessions = mergedor.fundir(maquina: machine, entradas: entradas)
            maquinasPendentes.remove(machine)
        }
    }
    maquinasPendentes = []
}
```

Com `private var mergedor = MergedorDeVivas(ordem: [])` e
`@Published var maquinasPendentes: Set<String> = []` no view model. Confira se `api` é capturável no
`addTask` (se `APIClient` não for `Sendable`, capture os valores que a chamada precisa, ou marque a
captura como já é feito em outro `Task` do arquivo).

- [ ] **Passo 6: não enfileirar o polling atrás do registro**

`:622`:

```swift
.task {
    // [13/08/2026] O ao vivo começa ANTES do await do registro. Antes, os ~11 s
    // da varredura das máquinas só COMEÇAVAM depois do `refresh()` terminar.
    model.startLiveUpdates()
    model.startLivePolling()
    await model.refresh()
    resolveDeepLink()
}
```

E `startLivePolling` passa `mostrandoCarga: true` só na primeira volta do laço; `.refreshable` (:618)
chama `await model.refresh()` e `await model.refreshLive(mostrandoCarga: true)`.

- [ ] **Passo 7: estado de carregando na seção "Ao vivo"**

Enquanto `!model.maquinasPendentes.isEmpty`, uma linha ao fim da seção:

```swift
if !model.maquinasPendentes.isEmpty {
    HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Procurando sessões em \(model.maquinasPendentes.sorted().joined(separator: ", "))…")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
```

Nomear as máquinas pendentes é de propósito: é o que mostra que a demora é de uma máquina específica
(o `windows` desligado), não do app.

- [ ] **Passo 8: o `:1131` da varredura de cor**

`var color: Color = .blue` como valor padrão de parâmetro não vê ambiente. Troque para `Color?` com
`nil` = "usa a de destaque", resolvendo na view com `@Environment(\.corDeDestaque)`.

- [ ] **Passo 9: suíte completa + commit**

---

## Integração (orquestrador, depois das frentes)

- [ ] Merge das seis branches em `abas-navegador-base`, na ordem F1, F3, F4, F5, F6, F2 (a varredura por
  último: ela toca mais arquivos e é a que mais sofre conflito).
- [ ] `xcodegen generate` (duas vezes: `project.yml` e `project-notest-watch.yml`) e suíte completa —
  esperado **≥479** com os testes novos somados.
- [ ] `grep -rn "Color.accentColor" app/CutuqueApp | wc -l` → **0**.
- [ ] `grep -rn "EstiloDeAba\|passagem" app/CutuqueApp` → nada além de comentário histórico.
- [ ] Build de device com o watch, no **checkout dela**:
  `xcodebuild build -project CutuqueApp.xcodeproj -scheme CutuqueApp -destination 'generic/platform=iOS'`
  — é o único caminho que compila o app do relógio, e foi o que pegou o piso do SwiftTerm em 13/08.
- [ ] Revisão adversarial de cada frente + a etapa fixa: revisão **só** do commit da onda 0.
- [ ] Memória: reescrever a decisão da aba de passagem em
  `memory/cutuque/specs/Specs — Abas no iPad, Novo Terminal tmux e Estado por Agente.md` (linha 24) com
  a razão nova e a data — **reescrever, não apagar** — e registrar a leva.

## Conferência dela (não é teste automatizado)

1. Abrir três sessões seguidas: as três ficam na barra, lado a lado.
2. Trocar a cor em Preferências: barra de abas, Board, cartões de pergunta e botões primários mudam
   juntos; vermelho de matar e verde de aprovar não mudam.
3. Aba do Board e aba de máquina: ⤡ leva a tela cheia, ⌘⌃F também.
4. Terminal ao vivo: o seletor Terminal/Info aparece na faixa embaixo das abas.
5. Editar máquina: ícone e tema estão lá; mudar aplica e o terminal aberto muda de cor.
6. Abrir o app com o `windows` desligado: as sessões do macbook aparecem em ~1 s, com a linha
   "Procurando sessões em windows…" enquanto o resto não respondeu.
