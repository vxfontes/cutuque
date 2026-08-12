# Abas globais no iPad (Board, Máquinas, Arquivo) + testes da fiação dos retratos

> **For agentic workers:** cada task abaixo é executada por UM subagente, num worktree próprio. Steps usam checkbox (`- [ ]`).

**Goal:** a barra de abas passa a ser a coluna de detalhe de TODOS os destinos do iPad, com UM conjunto global de abas (Board, máquina e card arquivado viram aba como sessão já é), e a fiação dos dois flags de retrato ganha teste automático.

**Architecture:** o modelo (`OpenTabs`) já sabe representar as cinco espécies de aba — o que falta é (a) alguém criá-las, (b) alguém RESOLVER as restauradas do disco, (c) um ciclo de vida por `TerminalPaneState` para o `ssh` da aba de máquina, e (d) mover a barra para a coluna de detalhe de todos os destinos. A sidebar e a coluna do meio passam a ser "onde eu abro as coisas" (o explorer do VS Code), não "o que está aberto".

**Tech Stack:** Swift 6 / SwiftUI, iPadOS 26, XCTest.

## Decisões da Vanessa que este plano obedece (12/08/2026)

1. **Arranjo: abas globais, modelo VS Code.** UM conjunto de abas, na coluna de detalhe de todos os destinos. Tocar em Board na sidebar abre/foca a **aba** do Board; tocar numa máquina abre/foca a aba dela; voltar para Sessões troca a LISTA, **não** a aba escolhida.
2. **`ssh` da aba de máquina: mesma regra do terminal ao vivo.** Aba em foco = trabalhando; aba viva atrás de outra = conectada mas sem ler (preserva o shell, o `cd`, o comando rodando); aba que dorme pelo teto de 6, ou que é fechada = desconecta, e o hub mata o `ssh`. **Custo aceito: uma conexão `ssh` por aba de máquina aberta, até o teto.**

## Global Constraints

- **pt-BR em tudo**: código, testes, comentários e texto de tela.
- **Nunca apague um comentário que documenta um bug ou uma decisão de arquitetura.** Se a sua mudança o tornar falso, **REESCREVA** com a razão nova e a data (12/08/2026).
- **Runtime do watchOS está quebrado nesta máquina.** Teste SEMPRE por `app/CutuqueAppNoWatch.xcodeproj`, nunca por `app/CutuqueApp.xcodeproj`. Atenção: só o **projeto** se chama `CutuqueAppNoWatch` — o **scheme** dentro dele é `CutuqueApp` (confirmado por `xcodebuild -list` em 12/08/2026). O comando certo é `-project CutuqueAppNoWatch.xcodeproj -scheme CutuqueApp`.
- **Arquivo `.swift` novo ou renomeado** exige regenerar OS DOIS projetos, de dentro de `app/`: `xcodegen generate && xcodegen generate --spec project-notest-watch.yml`.
- **`xcodebuild` sempre com `timeout: 600000`** e mirando o simulador **pelo UDID que a sua task recebe** — dois builds no mesmo simulador colidem ("Early unexpected exit… test runner exited before establishing connection").
- **`git add` só com caminhos explícitos.** NUNCA `git add -A` / `git add .`. Nunca commite: `scripts/tmx.sh`, `app/Local.xcconfig`, `app/project-notest-watch.yml`, `app/CutuqueAppNoWatch.xcodeproj`.
- **Teto de 3 arquivos de produção por task.** Se precisar de um 4º, PARE e devolva `falhou` com o motivo — não estenda escopo.
- `status: ok` não é prova: toda task termina confirmando os números da suíte com
  `xcrun xcresulttool get test-results summary --path <bundle>.xcresult`.

## File Structure

| Arquivo | Responsabilidade | Task |
|---|---|---|
| `app/CutuqueApp/SessionListAPI.swift` (novo) | protocolo estreito com os 8 métodos que `SessionListViewModel` usa + `extension APIClient` | T1 |
| `app/CutuqueApp/SessionListView.swift` | injeção de `api`/saúde no `SessionListViewModel` | T1 |
| `app/CutuqueApp/OpenTabs.swift` | símbolo por tipo de aba; aba de Board nasce resolvida; máquina/arquivo passam a ser julgáveis | T2 |
| `app/CutuqueApp/AbasResolver.swift` (novo) | resolve aba restaurada de máquina/arquivo (senão gira `ProgressView` pra sempre) | T3 |
| `app/CutuqueApp/MachineTerminalLifecycle.swift` (novo) | decisão pura: trabalhar / suspender / desconectar | T4 |
| `app/CutuqueApp/MachineDetailView.swift` | passa a obedecer `TerminalPaneState` (num `ZStack` de abas o `onDisappear` NUNCA roda) | T4 |
| `app/CutuqueApp/RootSplitView.swift` | barra de abas global na coluna de detalhe + criação das três abas novas | T5 |
| `app/CutuqueApp/NavigationState.swift` | layout passa a olhar "tem aba escolhida"; destino para de limpar seleção | T5 |
| `app/CutuqueApp/TabBar.swift` | ícone por tipo de aba | T5 |

**Paralelismo:** T1, T2, T3 e T4 mexem em arquivos DISJUNTOS e rodam ao mesmo tempo. T5 depende das quatro (usa `TipoDeAba.simbolo`, `AbasResolver` e a nova assinatura de `MachineDetailView`) e roda depois do merge.

---

### Task 1: Costura de API — testar a fiação dos retratos

**Por que existe:** achado `importante` da revisão adversarial da fase 5. `temRetratoDoRegistro` e `temRetratoDosVivos` decidem quem vira aba `.morta`, e não têm NENHUM teste automático porque `SessionListViewModel` tem `private let api = APIClient()` (linha 72 de `SessionListView.swift`) — não injetável. `APIClient` é uma struct com 75 `func`s: um protocolo completo seria absurdo; a costura é um protocolo **estreito**.

**Files:**
- Create: `app/CutuqueApp/SessionListAPI.swift`
- Modify: `app/CutuqueApp/SessionListView.swift` (linhas 72-73 e o `init` do `SessionListViewModel`)
- Test: `app/CutuqueAppTests/SessionListRetratosTests.swift` (novo)

**Interfaces — Produces:**

```swift
/// A fatia do `APIClient` que a lista de sessões consome. Estreito de
/// propósito: `APIClient` tem 75 funcs, e um protocolo com todas elas seria
/// cerimônia sem leitor. Existe para que os dois flags de retrato
/// (`temRetratoDoRegistro`/`temRetratoDosVivos`) — que decidem quem vira aba
/// `.morta` — tenham teste (12/08/2026, achado `importante` da revisão da
/// fase 5).
@MainActor
protocol SessionListAPI {
    func sessions() async throws -> [Session]
    func targets() async throws -> [String]
    func tmuxList(machine: String) async -> [DiscoveredSession]
    func deleteSession(id: String) async throws
    func resolve(sessionID: String) async throws
    func tmuxKillServer(machine: String, socket: String) async throws
    func liveUpdates() -> AsyncStream<WSMessage>
}

extension APIClient: SessionListAPI {}
```

**Atenção:** as assinaturas acima foram copiadas de `APIClient.swift` (`sessions()` :35, `targets()` :83, `deleteSession(id:)` :102, `tmuxList(machine:)` :861 — **não** tem `throws**, `tmuxKillServer(machine:socket:)` :959, `resolve(sessionID:)` :1166 — **não** devolve nada, `liveUpdates()` :1245). Confira cada uma no arquivo antes de escrever; se alguma divergir, use a do arquivo e diga qual no relato. Se `extension APIClient: SessionListAPI {}` não compilar por `@MainActor`/`Sendable`, ajuste o protocolo (é ele que existe pra servir, não o contrário) e relate.

O `init` do ViewModel injeta também a checagem de saúde, por um motivo prático: `refresh()` faz `async let statusResult = health.check()`, e num teste sem hub isso esperaria o timeout do `URLSession` inteiro.

```swift
// dentro de SessionListViewModel
private let api: SessionListAPI
private let checarSaude: () async -> HealthStatus

init(api: SessionListAPI = APIClient(),
     checarSaude: @escaping () async -> HealthStatus = { await HealthClient().check() }) {
    self.api = api
    self.checarSaude = checarSaude
}
```

`refresh()` troca `async let statusResult = health.check()` por `async let statusResult = checarSaude()`. O campo `private let health = HealthClient()` sai (nenhum outro método o usa — CONFIRME com `grep -n "health\." app/CutuqueApp/SessionListView.swift` antes de remover; se houver outro uso, mantenha o campo e injete só o `api`, relatando o desvio).

- [ ] **Step 1: leia o terreno**

```bash
grep -n "api\.\|health\." app/CutuqueApp/SessionListView.swift
grep -n "SessionListViewModel(" -r app/CutuqueApp app/CutuqueAppTests
```

Todo `api.` que aparecer TEM de estar no protocolo. Se algum chamador construir `SessionListViewModel()` com argumentos, o valor padrão do `init` já o cobre.

- [ ] **Step 2: escreva os testes que falham**

`app/CutuqueAppTests/SessionListRetratosTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

/// Dublê do `SessionListAPI`. Conta chamadas e devolve o que o teste mandar —
/// é o que torna testável o INSTANTE em que cada flag de retrato late.
@MainActor
final class APIFalsa: SessionListAPI {
    var sessoesParaDevolver: [Session] = []
    var erroEmSessions: Error?
    var alvos: [String] = []
    var panesPorMaquina: [String: [DiscoveredSession]] = [:]
    var mensagensDoStream: [WSMessage] = []
    private(set) var chamouTmuxList = 0

    func sessions() async throws -> [Session] {
        if let erroEmSessions { throw erroEmSessions }
        return sessoesParaDevolver
    }
    func targets() async throws -> [String] { alvos }
    func tmuxList(machine: String) async -> [DiscoveredSession] {
        chamouTmuxList += 1
        return panesPorMaquina[machine] ?? []
    }
    func deleteSession(id: String) async throws {}
    func resolve(sessionID: String) async throws {}
    func tmuxKillServer(machine: String, socket: String) async throws {}
    func liveUpdates() -> AsyncStream<WSMessage> {
        let msgs = mensagensDoStream
        return AsyncStream { cont in
            for m in msgs { cont.yield(m) }
            cont.finish()
        }
    }
}

@MainActor
final class SessionListRetratosTests: XCTestCase {
    private func modelo(_ api: APIFalsa) -> SessionListViewModel {
        SessionListViewModel(api: api, checarSaude: { .offline })
    }

    // MARK: retrato do registry

    func testRefreshComSucessoLigaORetratoDoRegistro() async {
        let api = APIFalsa()
        api.sessoesParaDevolver = []          // vazio de VERDADE também é retrato
        let m = modelo(api)
        XCTAssertFalse(m.temRetratoDoRegistro)
        await m.refresh()
        XCTAssertTrue(m.temRetratoDoRegistro)
    }

    func testRefreshQueFalhaNaoLigaORetratoDoRegistro() async {
        let api = APIFalsa()
        api.erroEmSessions = URLError(.notConnectedToInternet)
        let m = modelo(api)
        await m.refresh()
        XCTAssertFalse(m.temRetratoDoRegistro,
                       "REST que falhou não é retrato — ligar aqui mataria aba de chat viva")
    }

    func testUpsertDeUmaSessaoNaoLigaORetratoDoRegistro() async {
        let api = APIFalsa()
        api.mensagensDoStream = [.sessionUpdated(sessaoDeTeste(id: "s1"))]
        let m = modelo(api)
        m.startLiveUpdates()
        // Espera o efeito OBSERVÁVEL do upsert em vez de dormir por tempo.
        await esperar(até: { m.sessions.contains { $0.id == "s1" } })
        XCTAssertFalse(m.temRetratoDoRegistro,
                       "uma sessão só não é retrato completo do registry")
        m.stopLiveUpdates()
    }

    func testSnapshotDoWebSocketLigaORetratoDoRegistro() async {
        let api = APIFalsa()
        api.mensagensDoStream = [.snapshot([sessaoDeTeste(id: "s1")])]
        let m = modelo(api)
        m.startLiveUpdates()
        await esperar(até: { m.temRetratoDoRegistro })
        XCTAssertTrue(m.temRetratoDoRegistro)
        m.stopLiveUpdates()
    }

    // MARK: retrato dos vivos

    func testRefreshLiveSemMaquinaNaoLigaORetratoDosVivos() async {
        let api = APIFalsa()
        api.alvos = []                        // sem como consultar
        let m = modelo(api)
        await m.refreshLive()
        XCTAssertFalse(m.temRetratoDosVivos,
                       "sem máquina pra consultar não há retrato — só ausência de dado")
        XCTAssertEqual(api.chamouTmuxList, 0)
    }

    func testRefreshLiveComPaneLigaORetratoDosVivos() async {
        let api = APIFalsa()
        api.alvos = ["macmini"]
        api.panesPorMaquina = ["macmini": [paneDeTeste(id: "cutuque:0.0")]]
        let m = modelo(api)
        await m.refreshLive()
        XCTAssertTrue(m.temRetratoDosVivos)
        XCTAssertEqual(m.liveSessions.count, 1)
    }

    func testPrimeiroPollVazioDepoisDeTerPaneNaoLigaORetratoDosVivos() async {
        let api = APIFalsa()
        api.alvos = ["macmini"]
        api.panesPorMaquina = ["macmini": [paneDeTeste(id: "cutuque:0.0")]]
        let m = modelo(api)
        await m.refreshLive()                 // 1º poll: tem pane, liga o flag
        XCTAssertTrue(m.temRetratoDosVivos)

        // A guarda do hiccup de SSH: um poll vazio com sessões antigas NÃO é
        // retrato, e o early return dele acontece ANTES da linha do flag.
        // Como o flag já está ligado (e nunca volta a false), o que este teste
        // prova é o OUTRO lado da guarda: a lista não é zerada no 1º vazio.
        api.panesPorMaquina = [:]
        await m.refreshLive()
        XCTAssertEqual(m.liveSessions.count, 1, "1 leitura vazia é hiccup, não verdade")

        await m.refreshLive()                 // 2ª vazia seguida: agora é verdade
        XCTAssertTrue(m.liveSessions.isEmpty)
    }

    func testRefreshLiveVazioDesdeOInicioNaoAcumulaStreak() async {
        // Máquina existe, nenhum pane, e NADA antigo em cache: não é hiccup —
        // é retrato de "não tem nada rodando". Late na primeira.
        let api = APIFalsa()
        api.alvos = ["macmini"]
        let m = modelo(api)
        await m.refreshLive()
        XCTAssertTrue(m.temRetratoDosVivos)
        XCTAssertTrue(m.liveSessions.isEmpty)
    }

    // MARK: auxiliares

    /// Espera uma condição virar verdadeira em passos curtos (até ~2s) em vez
    /// de dormir um tempo fixo — o `liveTask` é privado e não dá pra `await`.
    private func esperar(até condicao: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condicao() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condição nunca ficou verdadeira")
    }
}
```

`sessaoDeTeste(id:)` e `paneDeTeste(id:)`: **não invente os campos.** Procure um construtor já usado nos testes existentes (`grep -rn "Session(" app/CutuqueAppTests | head`) e reaproveite o padrão do arquivo mais próximo (`LiveHubTests.swift`, `SessionListViewAtalhosTests.swift`). Se `Session`/`DiscoveredSession` só forem `Decodable`, construa por JSON com `JSONDecoder`, como os testes existentes fizerem.

- [ ] **Step 3: rode e veja falhar** (não compila: `SessionListViewModel` não tem `init(api:checarSaude:)`)

```bash
cd app && xcodebuild test -project CutuqueAppNoWatch.xcodeproj -scheme CutuqueApp \
  -destination 'platform=iOS Simulator,id=<UDID_DA_SUA_TASK>' \
  -only-testing:CutuqueAppTests/SessionListRetratosTests 2>&1 | tail -30
```

- [ ] **Step 4: crie `SessionListAPI.swift` e injete no ViewModel** (regenere os dois projetos — arquivo novo)

- [ ] **Step 5: rode até passar**, depois rode a SUÍTE INTEIRA e confirme os números no `.xcresult`

- [ ] **Step 6: commit**

```bash
git add app/CutuqueApp/SessionListAPI.swift app/CutuqueApp/SessionListView.swift \
        app/CutuqueAppTests/SessionListRetratosTests.swift app/project.yml
git commit -m "test(abas): costura estreita de API pra testar a fiação dos retratos"
```

(`app/project.yml` só entra se você tiver mexido nele; `CutuqueApp.xcodeproj/project.pbxproj` entra se o `xcodegen` o tiver alterado — confira com `git status --short` e adicione explicitamente.)

---

### Task 2: Modelo — símbolo por tipo, aba de Board nasce resolvida, máquina/arquivo julgáveis

**Por que existe:** hoje `dependeDeAlgoVivo` devolve `false` para `.board`, `.maquina` e `.arquivado`, e ninguém resolve o conteúdo delas. Uma aba dessas restaurada do disco nasce `.pendente` e **gira `ProgressView` para sempre**. Board se resolve sozinho (não depende de nada do hub); máquina e arquivo passam a ter uma autoridade (Task 3), e é a disciplina do `julgando` que impede a ausência de matá-las antes de o retrato dessa autoridade chegar.

**Files:**
- Modify: `app/CutuqueApp/OpenTabs.swift`
- Test: `app/CutuqueAppTests/OpenTabsTests.swift`

**Interfaces — Produces:** `TipoDeAba.simbolo: String` (SF Symbol), consumido pela `TabBar` na Task 5.

- [ ] **Step 1: escreva os testes que falham** (em `OpenTabsTests.swift`, seguindo o estilo do arquivo)

```swift
func testAbaDeBoardRestauradaNasceResolvida() {
    let salvas = [AbaPersistida(chave: .board, titulo: "Board", fixa: false)]
    let t = OpenTabs.restaurando(salvas)
    XCTAssertEqual(t.abas.first?.conteudo, .board,
                   "Board não depende de nada do hub — nascer .pendente giraria ProgressView pra sempre")
}

func testAbaDeMaquinaRestauradaNascePendente() {
    let salvas = [AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false)]
    let t = OpenTabs.restaurando(salvas)
    XCTAssertEqual(t.abas.first?.conteudo, .pendente,
                   "máquina precisa da Machine de verdade (tema, ícone) — quem resolve é o AbasResolver")
}

func testMaquinaAusenteMorreSoQuandoOTipoEstaSendoJulgado() {
    var t = OpenTabs.restaurando([
        AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false)
    ])
    // Retrato só do registry: a aba de máquina NÃO pode morrer por ausência.
    t.reconciliar(vivas: [:], julgando: [.chat])
    XCTAssertEqual(t.abas.first?.conteudo, .pendente)

    // Retrato das máquinas, e ela não está lá: agora sim.
    t.reconciliar(vivas: [:], julgando: [.maquina])
    XCTAssertEqual(t.abas.first?.conteudo, .morta)
}

func testAbaDeBoardNuncaMorrePorAusencia() {
    var t = OpenTabs.restaurando([AbaPersistida(chave: .board, titulo: "Board", fixa: false)])
    t.reconciliar(vivas: [:])   // padrão: julga TODOS os tipos
    XCTAssertEqual(t.abas.first?.conteudo, .board,
                   "Board é tela do hub, não pane: não há autoridade que possa dizer que ele não existe")
}

func testTodoTipoTemSimbolo() {
    for tipo in TipoDeAba.allCases {
        XCTAssertFalse(tipo.simbolo.isEmpty)
    }
}
```

- [ ] **Step 2: rode e veja falhar**

- [ ] **Step 3: implemente**

```swift
enum TipoDeAba: String, Codable, CaseIterable {
    case live, chat, board, maquina, arquivado

    /// Ícone da aba na barra. Os três últimos são os MESMOS símbolos dos
    /// destinos da sidebar (`PadDestination.symbol`) de propósito: com abas
    /// globais (12/08/2026) a sidebar é "onde eu abro" e a barra é "o que está
    /// aberto" — o mesmo desenho nos dois lugares é o que liga uma coisa à outra.
    var simbolo: String {
        switch self {
        case .live:      return "apple.terminal"
        case .chat:      return "bubble.left.and.bubble.right"
        case .board:     return "rectangle.split.3x1"
        case .maquina:   return "server.rack"
        case .arquivado: return "archivebox"
        }
    }
}
```

Em `restaurando(_:)`, o conteúdo inicial deixa de ser sempre `.pendente`:

```swift
for (i, s) in salvas.enumerated() {
    t.abas.append(AbaAberta(chave: s.chave, titulo: s.titulo, estilo: .normal,
                            fixa: s.fixa, conteudo: Self.conteudoInicial(s.chave),
                            ordemDeFoco: salvas.count - i))
}

/// O que uma aba restaurada do disco já pode mostrar sem perguntar a ninguém.
/// Só o Board: ele não tem carga útil nenhuma além da própria identidade
/// (12/08/2026 — abas globais). Máquina precisa da `Machine` de verdade (tema,
/// ícone, SO) e card arquivado precisa do `BoardTask`; as duas nascem
/// `.pendente` e quem as resolve é o `AbasResolver`. Sessão (`.live`/`.chat`)
/// nasce `.pendente` pelo motivo de sempre (D2): restaurar NÃO recria pane.
private static func conteudoInicial(_ chave: ChaveDeAba) -> TabConteudo {
    chave.tipo == .board ? .board : .pendente
}
```

E `dependeDeAlgoVivo` — **reescreva o comentário existente**, não o apague:

```swift
/// Quem pode virar `.morta` por AUSÊNCIA no retrato de quem está julgando.
///
/// [Reescrito em 12/08/2026, abas globais] Antes deste dia, `.maquina` e
/// `.arquivado` devolviam `false` com a justificativa de que "o host existe no
/// registro mesmo com o ssh caído, e quem mostra 'não conectei' é a própria
/// tela da máquina". A razão continua verdadeira para o `ssh` — e é justamente
/// por isso que ela não serve mais para a ABA: desde que máquina e card
/// arquivado podem ser abas restauradas do disco, existe um caso em que a aba
/// aponta para algo que o hub NÃO tem mais (máquina apagada, semana que nunca
/// existiu), e aí `false` significaria `ProgressView` girando para sempre. Quem
/// julga esses dois é o `AbasResolver`, com o retrato de `listMachines()` /
/// `boardArchive()` — e é o parâmetro `julgando` de `reconciliar` que garante
/// que só quem TEM retrato agora possa matar por ausência (a lista de sessões
/// nunca passa `.maquina`/`.arquivado`, então o poll de vivas não encosta
/// nelas).
///
/// `.board` segue `false`, e agora por um motivo mais forte que "é tela do
/// hub": não existe autoridade que possa dizer que o Board não existe. Ele
/// nasce resolvido em `conteudoInicial`.
private static func dependeDeAlgoVivo(_ tipo: TipoDeAba) -> Bool {
    switch tipo {
    case .live, .chat, .maquina, .arquivado: return true
    case .board:                             return false
    }
}
```

- [ ] **Step 4: audite os chamadores de `reconciliar`** — `grep -rn "reconciliar(" app/CutuqueApp app/CutuqueAppTests`. O `julgando` padrão é "todos os tipos", então qualquer teste antigo que chame `reconciliar(vivas:)` com aba de máquina no conjunto muda de comportamento. Conserte o teste (o comportamento novo é o desejado) e diga no relato quais mudaram.

- [ ] **Step 5: suíte inteira verde + números confirmados no `.xcresult`**

- [ ] **Step 6: commit**

```bash
git add app/CutuqueApp/OpenTabs.swift app/CutuqueAppTests/OpenTabsTests.swift
git commit -m "feat(abas): aba de Board nasce resolvida; máquina/arquivo julgáveis; símbolo por tipo"
```

---

### Task 3: `AbasResolver` — resolver aba restaurada de máquina e de arquivo

**Por que existe:** uma aba de máquina/arquivo restaurada do disco guarda só a CHAVE (`AbaPersistida` é deliberadamente pequena — guardar `Machine`/`BoardTask` inteiros congelaria dados que envelhecem). Alguém tem de buscar o objeto de verdade e casar por identidade. Sem isso a aba fica `.pendente` para sempre.

**Files:**
- Create: `app/CutuqueApp/AbasResolver.swift`
- Test: `app/CutuqueAppTests/AbasResolverTests.swift`

**Interfaces — Consumes:** `OpenTabs.reconciliar(vivas:julgando:)`, `OpenTabsStore.mutar`, `ChaveDeAba.maquina(_:)`, `ChaveDeAba.arquivado(_:)`, `Machine` (campo `name`), `ArchivedWeek` (campo `tasks: [BoardTask]`), `APIClient.listMachines() async throws -> [Machine]` (:461), `APIClient.boardArchive() async throws -> [ArchivedWeek]` (:140).

**Interfaces — Produces (a Task 5 usa exatamente isto):**

```swift
enum AbasResolucao {
    static func tiposPendentes(em abas: [AbaAberta]) -> Set<TipoDeAba>
    static func vivasDeMaquinas(_ maquinas: [Machine]) -> [ChaveDeAba: TabConteudo]
    static func vivasDeArquivo(_ semanas: [ArchivedWeek]) -> [ChaveDeAba: TabConteudo]
}

@MainActor
final class AbasResolver: ObservableObject {
    init(carregarMaquinas: @escaping () async throws -> [Machine] = { try await APIClient().listMachines() },
         carregarArquivo: @escaping () async throws -> [ArchivedWeek] = { try await APIClient().boardArchive() })
    func resolver(_ store: OpenTabsStore) async
}
```

Closures em vez de um protocolo: são duas chamadas, e um dublê de closure não arrasta as outras 73 funcs do `APIClient` para dentro do teste.

- [ ] **Step 1: escreva os testes que falham**

`app/CutuqueAppTests/AbasResolverTests.swift`:

```swift
import XCTest
@testable import CutuqueApp

@MainActor
final class AbasResolverTests: XCTestCase {

    private func store(_ salvas: [AbaPersistida]) -> OpenTabsStore {
        let s = OpenTabsStore()
        s.mutar { $0 = OpenTabs.restaurando(salvas) }
        return s
    }

    func testTiposPendentesSoContaOQuePrecisaDeBusca() {
        let t = OpenTabs.restaurando([
            AbaPersistida(chave: .board, titulo: "Board", fixa: false),
            AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false),
        ])
        XCTAssertEqual(AbasResolucao.tiposPendentes(em: t.abas), [.maquina],
                       "Board já nasce resolvido; só quem está .pendente entra")
    }

    func testMaquinaPresenteResolveEAusenteMorre() async {
        let s = store([
            AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false),
            AbaPersistida(chave: .maquina("sumida"), titulo: "sumida", fixa: false),
        ])
        let r = AbasResolver(carregarMaquinas: { [maquinaDeTeste(nome: "macmini")] },
                            carregarArquivo: { XCTFail("não havia aba de arquivo pendente"); return [] })
        await r.resolver(s)
        XCTAssertEqual(s.tabs.aba(.maquina("macmini"))?.conteudo,
                       .maquina(maquinaDeTeste(nome: "macmini")))
        XCTAssertEqual(s.tabs.aba(.maquina("sumida"))?.conteudo, .morta)
    }

    func testCargaQueFalhaNaoMataAba() async {
        let s = store([AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false)])
        let r = AbasResolver(carregarMaquinas: { throw URLError(.timedOut) },
                            carregarArquivo: { [] })
        await r.resolver(s)
        XCTAssertEqual(s.tabs.aba(.maquina("macmini"))?.conteudo, .pendente,
                       "erro de rede não é retrato: ausência de dado ≠ ausência do mundo")
    }

    func testSemPendenteNaoBuscaNada() async {
        let s = store([AbaPersistida(chave: .board, titulo: "Board", fixa: false)])
        var buscou = false
        let r = AbasResolver(carregarMaquinas: { buscou = true; return [] },
                            carregarArquivo: { buscou = true; return [] })
        await r.resolver(s)
        XCTAssertFalse(buscou, "sem ninguém esperando, não se toca no hub")
    }

    func testCardArquivadoResolvePeloID() async {
        let card = cardDeTeste(id: "c1", titulo: "Fechar semana")
        let s = store([AbaPersistida(chave: .arquivado("c1"), titulo: "Fechar semana", fixa: false)])
        let r = AbasResolver(carregarMaquinas: { [] },
                            carregarArquivo: { [semanaDeTeste(label: "2026-W28", tasks: [card])] })
        await r.resolver(s)
        XCTAssertEqual(s.tabs.aba(.arquivado("c1"))?.conteudo, .arquivado(card))
    }

    func testResolverNaoEncostaEmAbaDeSessao() async {
        // Uma aba .live pendente (cold start) não pode virar .morta porque o
        // retrato das MÁQUINAS chegou — é o mesmo erro que o `julgando`
        // existe pra impedir (críticos #A/#B da fase 5).
        let s = store([
            AbaPersistida(chave: ChaveDeAba(tipo: .live, machine: "macmini", alvo: "cutuque:0.0"),
                          titulo: "claude", fixa: false),
            AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false),
        ])
        let r = AbasResolver(carregarMaquinas: { [maquinaDeTeste(nome: "macmini")] },
                            carregarArquivo: { [] })
        await r.resolver(s)
        XCTAssertEqual(s.tabs.abas.first?.conteudo, .pendente)
    }
}
```

`maquinaDeTeste`, `cardDeTeste`, `semanaDeTeste`: **não invente campos.** Veja como os testes existentes constroem `Machine`/`BoardTask` (`grep -rn "Machine(" app/CutuqueAppTests | head`, `MachineAppearanceTests.swift`, `BoardModelTests.swift`) e reaproveite; se forem só `Decodable`, monte por JSON.

⚠️ `OpenTabsStore()` escreve em `UserDefaults.standard` (chave `abasAbertas.v1`). Nos testes, salve e restaure o valor original em `setUp`/`tearDown`, ou limpe a chave, para não vazar estado entre testes. Se isso ficar frágil, relate — mas NÃO mude `OpenTabsStore` (é arquivo de outra task).

- [ ] **Step 2: rode e veja falhar**

- [ ] **Step 3: implemente `AbasResolver.swift`**

```swift
import Foundation

/// Decisões puras da resolução de abas restauradas (sem rede, sem View).
enum AbasResolucao {
    /// Tipos que têm alguma aba `.pendente` esperando resolução. É o que faz o
    /// resolver não tocar no hub quando ninguém está esperando.
    static func tiposPendentes(em abas: [AbaAberta]) -> Set<TipoDeAba> {
        Set(abas.filter { $0.conteudo == .pendente }.map { $0.chave.tipo })
    }

    /// Casa `ChaveDeAba.maquina(nome)` com a `Machine` de verdade. Pelo NOME,
    /// que é a chave do registro no hub e não muda por edição de tema/ícone.
    static func vivasDeMaquinas(_ maquinas: [Machine]) -> [ChaveDeAba: TabConteudo] {
        Dictionary(uniqueKeysWithValues: maquinas.map { (.maquina($0.name), .maquina($0)) })
    }

    /// Casa `ChaveDeAba.arquivado(id)` com o card de verdade, de todas as
    /// semanas fechadas.
    static func vivasDeArquivo(_ semanas: [ArchivedWeek]) -> [ChaveDeAba: TabConteudo] {
        var fora: [ChaveDeAba: TabConteudo] = [:]
        for semana in semanas {
            for card in semana.tasks { fora[.arquivado(card.id)] = .arquivado(card) }
        }
        return fora
    }
}

/// Resolve as abas que o disco restaurou sem carga útil: máquina e card
/// arquivado (12/08/2026 — abas globais). `AbaPersistida` guarda só a chave de
/// propósito, então alguém tem de buscar o objeto de verdade — e esse alguém
/// não pode ser a lista de sessões, que só conhece panes e registry.
///
/// Segue a MESMA disciplina que a revisão adversarial da fase 5 impôs à
/// reconciliação: só julga o tipo cujo retrato ele acabou de obter. Carga que
/// falhou não é retrato — ausência de dado ≠ ausência do mundo — e por isso o
/// `try?` aqui não é desleixo: é o que impede um timeout de rede de marcar
/// `.morta` uma máquina que existe.
@MainActor
final class AbasResolver: ObservableObject {
    private let carregarMaquinas: () async throws -> [Machine]
    private let carregarArquivo: () async throws -> [ArchivedWeek]

    init(carregarMaquinas: @escaping () async throws -> [Machine] = { try await APIClient().listMachines() },
         carregarArquivo: @escaping () async throws -> [ArchivedWeek] = { try await APIClient().boardArchive() }) {
        self.carregarMaquinas = carregarMaquinas
        self.carregarArquivo = carregarArquivo
    }

    func resolver(_ store: OpenTabsStore) async {
        let pendentes = AbasResolucao.tiposPendentes(em: store.tabs.abas)
        var vivas: [ChaveDeAba: TabConteudo] = [:]
        var julgando: Set<TipoDeAba> = []

        if pendentes.contains(.maquina), let maquinas = try? await carregarMaquinas() {
            vivas.merge(AbasResolucao.vivasDeMaquinas(maquinas)) { a, _ in a }
            julgando.insert(.maquina)
        }
        if pendentes.contains(.arquivado), let semanas = try? await carregarArquivo() {
            vivas.merge(AbasResolucao.vivasDeArquivo(semanas)) { a, _ in a }
            julgando.insert(.arquivado)
        }
        guard !julgando.isEmpty else { return }

        // Mesma manobra de `reconciliarAbas`: calcula num cópia e só publica se
        // mudou — `OpenTabs` é `Equatable`, e publicar igual repinta a árvore à toa.
        var candidato = store.tabs
        candidato.reconciliar(vivas: vivas, julgando: julgando)
        guard candidato != store.tabs else { return }
        store.mutar { $0 = candidato }
    }
}
```

- [ ] **Step 4: regenere os dois projetos** (arquivo novo), rode até passar, suíte inteira verde, números confirmados no `.xcresult`

- [ ] **Step 5: commit**

```bash
git add app/CutuqueApp/AbasResolver.swift app/CutuqueAppTests/AbasResolverTests.swift
git commit -m "feat(abas): AbasResolver resolve aba restaurada de máquina e de arquivo"
```

---

### Task 4: ciclo de vida do terminal da máquina por `TerminalPaneState`

**Por que existe:** `MachineDetailView` hoje suspende o `ssh` por `.onAppear`/`.onDisappear`. Dentro do `ZStack` de abas **o `onDisappear` nunca roda** (decisão #19: aba, uma vez criada, fica montada para sempre) — é exatamente o bug do `✕` do iPad outra vez. A aba precisa receber o estado de fora, como o terminal ao vivo já recebe.

**Decisão da Vanessa:** foco = trabalhando; viva atrás = conectada sem ler; dormindo (teto de 6) ou fechada = desconecta e o hub mata o `ssh`.

**Files:**
- Create: `app/CutuqueApp/MachineTerminalLifecycle.swift`
- Modify: `app/CutuqueApp/MachineDetailView.swift`
- Test: `app/CutuqueAppTests/MachineTerminalLifecycleTests.swift`

**Interfaces — Produces (a Task 5 usa exatamente isto):**

```swift
enum AcaoDoTerminalDaMaquina: Equatable { case trabalhar, suspender, desconectar }

enum MachineTerminalLifecycle {
    static func acao(paneState: TerminalPaneState, pane: MachinePane, naTela: Bool) -> AcaoDoTerminalDaMaquina
}

// MachineDetailView ganha um parâmetro COM valor padrão (mantém o iPhone e
// qualquer outro chamador compilando sem mudança):
init(machine: Machine, paneState: TerminalPaneState = .ativo)
```

- [ ] **Step 1: escreva os testes que falham**

```swift
import XCTest
@testable import CutuqueApp

final class MachineTerminalLifecycleTests: XCTestCase {
    func testAbaEmFocoNoTerminalTrabalha() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .terminal, naTela: true),
                       .trabalhar)
    }

    func testAbaVivaAtrasDeOutraSoSuspende() {
        // O shell, o `cd` e o comando rodando têm de sobreviver.
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .suspenso, pane: .terminal, naTela: true),
                       .suspender)
    }

    func testAbaQueDormeDesconecta() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .liberado, pane: .terminal, naTela: true),
                       .desconectar)
    }

    func testDesconectarVenceOPainelDeArquivos() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .liberado, pane: .files, naTela: false),
                       .desconectar)
    }

    func testPainelDeArquivosSuspendeSemDesconectar() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .files, naTela: true),
                       .suspender)
    }

    func testSubpastaEmpilhadaSuspendeSemDesconectar() {
        // `naTela: false` é a subpasta por cima: para de ler, socket segue aberto.
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .terminal, naTela: false),
                       .suspender)
    }
}
```

- [ ] **Step 2: rode e veja falhar**

- [ ] **Step 3: implemente o arquivo novo**

```swift
import Foundation

/// O que o terminal de uma máquina deve estar fazendo agora.
enum AcaoDoTerminalDaMaquina: Equatable {
    /// Conectado e lendo o socket.
    case trabalhar
    /// Conectado e calado — o shell, o `cd` e o comando rodando sobrevivem.
    case suspender
    /// Fecha o WebSocket; o hub mata o `ssh` junto (sessão efêmera, sem tmux atrás).
    case desconectar
}

/// Decisão pura do ciclo de vida do `ssh` da aba de máquina (12/08/2026 — abas
/// globais). Existe fora da View porque dentro do `ZStack` de abas o
/// `onDisappear` NUNCA roda (decisão #19: aba montada fica montada), então
/// `.onAppear`/`.onDisappear` deixaram de ser suficientes: sem isto, uma aba de
/// máquina que sai de foco continuaria lendo o socket para sempre e uma que
/// dorme pelo teto de 6 nunca devolveria o `ssh` — é o bug do `✕` do iPad
/// repetido.
///
/// Regra escolhida pela Vanessa: foco = trabalhando; viva atrás de outra aba =
/// conectada mas sem ler; dormindo (teto de 6) ou fechada = desconecta. O custo
/// aceito é uma conexão `ssh` por aba de máquina aberta, até o teto.
enum MachineTerminalLifecycle {
    static func acao(paneState: TerminalPaneState, pane: MachinePane,
                     naTela: Bool) -> AcaoDoTerminalDaMaquina {
        // `liberado` vence tudo: é a única transição que devolve recurso.
        if paneState == .liberado { return .desconectar }
        guard pane == .terminal, naTela, paneState == .ativo else { return .suspender }
        return .trabalhar
    }
}
```

- [ ] **Step 4: ligue na `MachineDetailView`**

```swift
struct MachineDetailView: View {
    let machine: Machine
    /// Estado do painel desta aba, vindo de fora (`OpenTabs.estado(de:)`).
    /// Padrão `.ativo` para os chamadores que não vivem em aba (iPhone).
    let paneState: TerminalPaneState

    init(machine: Machine, paneState: TerminalPaneState = .ativo) {
        self.machine = machine
        self.paneState = paneState
        // ... resto do init inalterado
    }

    /// O que o terminal deve estar fazendo agora — ver `MachineTerminalLifecycle`.
    private var acao: AcaoDoTerminalDaMaquina {
        MachineTerminalLifecycle.acao(paneState: paneState, pane: pane, naTela: naTela)
    }

    /// O terminal só trabalha quando esta é a decisão. Substitui o antigo
    /// `showsTerminal && naTela`: aquele não sabia de aba, e dentro do `ZStack`
    /// de abas ele ficava `true` em TODAS as abas de máquina ao mesmo tempo.
    private var terminalAtivo: Bool { acao == .trabalhar }
```

E o `.onChange` do fim do `body`:

```swift
        // `initial: true` porque uma aba pode NASCER dormindo (restaurada do
        // disco além do teto de 6): sem isto, a decisão só chegaria na primeira
        // transição, e `PTYTerminalView` só chama `abre()` quando `isActive`
        // (ver PTYTerminalView.swift:131) — então nascer dormindo já não abre
        // conexão, e nascer `.liberado` depois de ter aberto precisa fechar.
        .onChange(of: acao, initial: true) { _, acao in
            switch acao {
            case .trabalhar:
                // A ordem importa: `abre()` para quem nunca conectou (chegou
                // pelos arquivos, ou acordou depois de dormir); `resume()` para
                // quem já tinha uma conexão, suspensa.
                session.abre()
                session.resume()
            case .suspender:
                session.suspend()
            case .desconectar:
                session.disconnect()
            }
        }
```

**Mantenha** `.onAppear { naTela = true }` / `.onDisappear { naTela = false }` — eles continuam valendo para a subpasta empilhada dentro da `NavigationStack` da própria aba. **Reescreva o comentário deles** dizendo por que deixaram de ser suficientes sozinhos (data 12/08/2026, `ZStack` de abas, `onDisappear` que não roda).

Passe `isActive: terminalAtivo` como já está (`PTYTerminalView` e `FileBrowserView` não mudam de assinatura).

- [ ] **Step 5: audite os chamadores** — `grep -rn "MachineDetailView(" app/`. Todos têm de continuar compilando pelo valor padrão. Não mexa em `RootSplitView.swift` (é a Task 5); se algum outro chamador exigir mudança, relate.

- [ ] **Step 6: regenere os dois projetos, suíte inteira verde, números confirmados no `.xcresult`**

- [ ] **Step 7: commit**

```bash
git add app/CutuqueApp/MachineTerminalLifecycle.swift app/CutuqueApp/MachineDetailView.swift \
        app/CutuqueAppTests/MachineTerminalLifecycleTests.swift
git commit -m "feat(abas): ciclo de vida do ssh da aba de máquina por TerminalPaneState"
```

---

### Task 5: barra de abas global na coluna de detalhe + criar as três abas novas

**Depende de:** Tasks 2, 3 e 4 (usa `TipoDeAba.simbolo`, `AbasResolver` e `MachineDetailView(machine:paneState:)`). Só comece com as três já mergeadas na sua base.

**Files:**
- Modify: `app/CutuqueApp/RootSplitView.swift`
- Modify: `app/CutuqueApp/NavigationState.swift`
- Modify: `app/CutuqueApp/TabBar.swift`
- Test: `app/CutuqueAppTests/NavigationStateTests.swift` (e `RootSplitViewTests.swift` se houver caso afetado)

- [ ] **Step 1: `NavigationState` — o layout passa a olhar "tem aba escolhida"**

Hoje `layoutVisibility(isPortrait:)` decide o colapso de retrato por `selection != nil` (Sessões) e `machineSelection != nil` (Máquinas). Com abas globais o sinal certo é UM só: **existe aba escolhida?** — e ele já está na classe, em `abaEmFoco` (escrito por `RootSplitView` a partir de `OpenTabs.selecionada`, com `initial: true`). Nenhuma encanação nova.

```swift
    func layoutVisibility(isPortrait: Bool) -> NavigationSplitViewVisibility {
        switch destination {
        case .board:
            return .doubleColumn
        case .sessions:
            guard isPortrait else { return .all }
            // [12/08/2026 — abas globais] Era `selection != nil`. O sinal de
            // "tem coisa aberta" mudou de lugar: quem mostra o painel agora é a
            // barra de abas, e ela é global — voltar pra Sessões com uma aba de
            // máquina em foco tem de continuar em tela cheia, e uma sessão
            // "selecionada" na lista sem aba nenhuma escolhida não é nada
            // aberto. `abaEmFoco` é o mesmo dado que `nav.paneMode` já usa.
            return abaEmFoco != nil ? .detailOnly : .doubleColumn
        case .machines:
            // Mesma troca de sinal do caso acima (era `machineSelection != nil`).
            return (isPortrait && abaEmFoco != nil) ? .detailOnly : .all
        case .archive:
            return .all
        }
    }
```

E o `didSet` de `destination` **para de limpar as seleções** — reescreva o comentário, não o apague:

```swift
    /// [Reescrito em 12/08/2026 — abas globais] Trocar de destino NÃO limpa
    /// mais `selection`/`machineSelection`.
    ///
    /// A limpeza existia por duas razões que a barra de abas global desfez. A
    /// primeira: "sair pro Board e voltar pra Sessões caía direto na última
    /// sessão aberta em vez da lista" — em retrato a regra de layout colapsava
    /// pra `.detailOnly` quando havia seleção. Hoje quem decide o colapso é
    /// `abaEmFoco` (ver `layoutVisibility`), e cair na coisa que estava aberta é
    /// exatamente o desenho pedido: "voltar pra Sessões troca a LISTA, não a aba
    /// escolhida". A segunda: "as duas guardam conexão viva — sair da coluna
    /// destrói o painel, e voltar reabriria um terminal NOVO com cara do
    /// antigo". Também deixou de valer: o painel não mora mais na coluna do
    /// destino, mora na aba, e quem manda no `ssh`/no espelho é
    /// `OpenTabs.estado(de:)` (ver `MachineTerminalLifecycle`). Limpar aqui
    /// hoje só dessincronizaria a lista (sem linha destacada) da aba que segue
    /// aberta.
    @Published var destination: PadDestination = .sessions
```

Atualize `NavigationStateTests` (a tabela-verdade do layout) para o sinal novo: escreva `nav.abaEmFoco = <chave>` onde antes se escrevia `nav.selection`/`nav.machineSelection`, e ACRESCENTE um caso que o desenho novo exige: destino `.sessions`, retrato, `selection != nil` mas `abaEmFoco == nil` → `.doubleColumn` (lista, não painel).

- [ ] **Step 2: `TabBar` — ícone por tipo**

Dentro do `HStack` do `botao(_:)`, antes do `Text(aba.titulo)`:

```swift
                Image(systemName: aba.chave.tipo.simbolo)
                    .font(.caption2)
```

- [ ] **Step 3: `RootSplitView` — a barra vira a coluna de detalhe de TODOS os destinos**

`detailColumn` inteiro passa a ser:

```swift
    /// [12/08/2026 — abas globais] A coluna de detalhe é a MESMA em todos os
    /// destinos: a barra de abas e os painéis abertos. O destino manda só na
    /// coluna do meio ("onde eu abro as coisas", o explorer do VS Code) — e é
    /// por isso que trocar de destino não fecha nem troca a aba escolhida.
    /// Os `switch nav.destination` que havia aqui (Board direto no detalhe,
    /// `MachineDetailView` do `machineSelection`, `ArchivedTaskPane` do
    /// `archiveSelection`) saíram: os três agora chegam como aba, por
    /// `abrirAbaDoDestino`/`.onChange` abaixo. O `.id(machine.name)` que
    /// morava no case `.machines` continua vivo em `painel(_:)`, que é onde a
    /// máquina é renderizada agora.
    @ViewBuilder private var detailColumn: some View {
        if sessionListLivesInDetail {
            SessionListView(splitSelection: $nav.selection)
        } else {
            abasDetail
        }
    }
```

Renomeie `sessionTabsDetail` → `abasDetail` (é de todos os destinos agora) e ajuste o texto do vazio:

```swift
                if tabsStore.tabs.abas.isEmpty {
                    ContentUnavailableView("Nada aberto", systemImage: "square.on.square",
                                           description: Text("Toque numa sessão, no Board, numa máquina ou num card do arquivo."))
                }
```

`sessionListLivesInDetail` ganha uma condição — e o comentário existente é reescrito:

```swift
    /// ... (mantenha o texto atual, que explica a troca de coluna e o custo da
    /// remontagem, e ACRESCENTE:)
    ///
    /// [12/08/2026 — abas globais] `tabsStore.tabs.selecionada == nil` entrou na
    /// conta: com a barra de abas na coluna de detalhe, "retrato sem seleção"
    /// deixou de significar "não há nada aberto". Sem esta condição, abrir uma
    /// aba pelo Board e voltar pra Sessões em retrato esconderia a aba aberta
    /// atrás da lista.
    private var sessionListLivesInDetail: Bool {
        nav.destination == .sessions
            && nav.selection == nil
            && tabsStore.tabs.selecionada == nil
            && nav.columnVisibility == .doubleColumn
    }
```

`layoutRuleKey` troca os dois eixos de seleção pelo sinal de aba:

```swift
    private var layoutRuleKey: String {
        "\(nav.destination.rawValue)-\(isPortrait)-\(nav.abaEmFoco != nil)"
    }
```

(Reescreva o parágrafo do comentário que fala de "tem sessão escolhida"/"tem host aberto" explicando a troca — o motivo original, "escolher um host não muda `geo.size`", continua valendo, só mudou o dado observado.)

Três `.onChange` novos criam as abas (a de sessão continua nascendo dentro de `SessionListView.apply`, intocada):

```swift
        // [12/08/2026 — abas globais] Tocar no destino Board abre/foca a ABA do
        // Board. Sem `initial: true`: o destino inicial é sempre `.sessions`, e
        // abrir uma aba na montagem atropelaria a aba restaurada do disco.
        .onChange(of: nav.destination) { _, destino in
            guard destino == .board else { return }
            tabsStore.mutar {
                $0.abrir(chave: .board, titulo: "Board", conteudo: .board)
            }
        }
        // Escolher um host na lista abre/foca a aba dele. `estilo: .passagem`
        // (padrão) é o modelo do VS Code: a próxima coisa aberta substitui esta
        // se ela não tiver sido fixada.
        .onChange(of: nav.machineSelection) { _, machine in
            guard let machine else { return }
            tabsStore.mutar {
                $0.abrir(chave: .maquina(machine.name), titulo: machine.name,
                         conteudo: .maquina(machine))
            }
        }
        .onChange(of: nav.archiveSelection) { _, card in
            guard let card else { return }
            tabsStore.mutar {
                $0.abrir(chave: .arquivado(card.id), titulo: card.title,
                         conteudo: .arquivado(card))
            }
        }
```

**Confira o nome do campo de título do `BoardTask`** (`card.title` acima é palpite): `grep -n "struct BoardTask" -A 20 app/CutuqueApp/Models.swift`. Use o campo real.

O resolver das abas restauradas:

```swift
    /// Resolve as abas de máquina/arquivo que voltaram do disco só com a chave
    /// (ver `AbasResolver`). Sem isto elas girariam `ProgressView` pra sempre.
    @StateObject private var resolver = AbasResolver()

    /// Quais tipos estão esperando resolução AGORA — chave do `.task` abaixo,
    /// pra ele reentrar quando uma aba pendente nova aparecer (e não a cada
    /// repintura).
    private var chaveDePendentes: String {
        AbasResolucao.tiposPendentes(em: tabsStore.tabs.abas)
            .map(\.rawValue).sorted().joined(separator: ",")
    }
```

```swift
        .task(id: chaveDePendentes) {
            guard !chaveDePendentes.isEmpty else { return }
            await resolver.resolver(tabsStore)
        }
```

E `painel(_:)` muda em três pontos:

```swift
        case .maquina(let machine):
            // Mesmo motivo do `.id(machine.name)` de sempre: identidade pelo
            // NOME, não pela struct inteira (tema/ícone mudariam o id e
            // matariam o `ssh` por tabela). `paneState` é o que faz a aba de
            // máquina obedecer ao teto de 6 e parar de ler quando sai de foco —
            // num `ZStack` de abas o `onDisappear` dela NUNCA roda.
            NavigationStack {
                MachineDetailView(machine: machine,
                                  paneState: tabsStore.tabs.estado(de: aba.chave))
            }
            .id(machine.name)
        case .arquivado(let task):
            // `onClose` fecha a ABA. Zerar `nav.archiveSelection` (o que o
            // `ArchivedTaskPane` faz por padrão) não fecharia nada aqui — o
            // painel não vem mais da seleção — e o botão voltaria a ser
            // decorativo, que foi bug relatado antes (12/08/2026).
            ArchivedTaskPane(task: task) { tabsStore.mutar { $0.fechar(aba.chave) } }
        case .pendente:
            // Erro de rede não mata aba (ver `AbasResolver`), então sobra o
            // caso de ficar girando: o botão é a saída manual.
            VStack(spacing: 12) {
                ProgressView()
                Button("Tentar de novo") {
                    Task { await resolver.resolver(tabsStore) }
                }
                .buttonStyle(.bordered)
            }
        case .morta:
            abaMorta(aba.chave.tipo)
```

```swift
    /// D2: aviso, nunca recriação — fechar é decisão da Vanessa. O texto muda
    /// por tipo porque "Sessão encerrada" numa aba de máquina ou de card
    /// arquivado seria simplesmente falso (12/08/2026 — abas globais).
    @ViewBuilder private func abaMorta(_ tipo: TipoDeAba) -> some View {
        switch tipo {
        case .live, .chat, .board:
            ContentUnavailableView("Sessão encerrada", systemImage: "exclamationmark.triangle",
                                   description: Text("Essa sessão não está mais viva. A aba fica aqui até você fechá-la."))
        case .maquina:
            ContentUnavailableView("Máquina fora do registro", systemImage: "exclamationmark.triangle",
                                   description: Text("Esse host não está mais registrado no hub. A aba fica aqui até você fechá-la."))
        case .arquivado:
            ContentUnavailableView("Card não encontrado", systemImage: "exclamationmark.triangle",
                                   description: Text("Esse card não está mais no arquivo semanal. A aba fica aqui até você fechá-la."))
        }
    }
```

E `ArchivedTaskPane` (mora neste mesmo arquivo) ganha o fechamento injetável:

```swift
struct ArchivedTaskPane: View {
    let task: BoardTask
    /// Quem fecha. `nil` = comportamento de sempre (zerar a seleção do
    /// arquivo); numa aba, quem fecha é a aba (ver `painel(_:)`).
    var aoFechar: (() -> Void)?
    @EnvironmentObject private var nav: NavigationState
    @StateObject private var readOnlyModel = BoardModel()

    init(task: BoardTask, aoFechar: (() -> Void)? = nil) {
        self.task = task
        self.aoFechar = aoFechar
    }
    ...
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true,
                            onClose: { aoFechar?() ?? { nav.archiveSelection = nil }() })
```

(Se essa expressão ficar feia, escreva um `private func fechar()` — só mantenha os dois comportamentos.)

- [ ] **Step 4: `grep` de sobras** — `grep -n "machineSelection\|archiveSelection\|sessionTabsDetail" app/CutuqueApp/*.swift`. `machineSelection`/`archiveSelection` continuam existindo (a lista e o arquivo usam para destacar a linha escolhida); o que não pode sobrar é ninguém RENDERIZANDO painel a partir delas na coluna de detalhe.

- [ ] **Step 5: suíte inteira verde, números confirmados no `.xcresult`**

- [ ] **Step 6: commit**

```bash
git add app/CutuqueApp/RootSplitView.swift app/CutuqueApp/NavigationState.swift \
        app/CutuqueApp/TabBar.swift app/CutuqueAppTests/NavigationStateTests.swift
git commit -m "feat(abas): barra de abas global — Board, máquina e card arquivado viram aba"
```

---

## Verificações no iPad de verdade (a Vanessa faz)

1. Tocar em Board na sidebar abre uma aba "Board"; voltar pra Sessões mantém a aba do Board escolhida e troca só a lista do meio.
2. Abrir duas máquinas: as duas ficam como abas, cada uma com o seu shell; voltar de uma pra outra reencontra o `cd` e o comando rodando.
3. Abrir 7 abas: a 7ª derruba a mais antiga pro sono — a aba de máquina que dormiu perde o `ssh` (o hub mostra a sessão encerrada) e acordá-la abre um shell NOVO, sem aviso preso na tela.
4. Fechar a aba de uma máquina mata o `ssh` daquele host no hub.
5. Matar o app com uma aba de máquina e uma de Board abertas e reabrir: a do Board aparece na hora; a da máquina resolve em segundos (ou vira "Máquina fora do registro", se o host tiver sido apagado) — nenhuma fica girando pra sempre.
6. Em retrato, com uma aba aberta, voltar pra Sessões: o painel continua em tela cheia (não volta pra lista).
