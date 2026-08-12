import XCTest
@testable import CutuqueApp

/// Cobre a decisão pura extraída de `resolveDeepLink()` e `go(to:)` da
/// `SessionListView` (review Task 6, achado Important: zero teste para a
/// mudança de embed — `splitSelection` vs. `tmuxTarget` vs. `path`). A
/// extração não pode mudar o comportamento observável nos dois modos.
final class SessionNavigationLogicTests: XCTestCase {

    /// `Session` só tem init de decoder — monta uma a partir de JSON, como o
    /// hub manda (snake_case, RFC3339).
    private func session(id: String = "s1", pane: String? = nil) -> Session {
        let paneJSON = pane.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"\(id)","machine":"macbook","agent":"claude-code","title":"t",
         "state":"running","created_at":"2026-07-26T10:00:00Z",
         "updated_at":"2026-07-26T10:00:00Z","pane":\(paneJSON)}
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    private func liveEntry(for session: Session, target: String) -> LiveEntry {
        LiveEntry(machine: session.machine,
                  session: DiscoveredSession(id: target, cwd: session.cwd ?? "", title: session.title))
    }

    // MARK: resolveDeepLink — sessão COM tmuxTarget

    func testDeepLinkSessaoComTmuxTargetEmbutidoViraSelecaoAoVivo() {
        let s = session(pane: "main\t%3")
        let entry = liveEntry(for: s, target: "main\t%3")
        let target = SessionNavigationLogic.deepLink(session: s, tmuxEntry: entry, embedded: true, pathTopID: nil)
        XCTAssertEqual(target, .selection(.live(entry)))
    }

    func testDeepLinkSessaoComTmuxTargetNaoEmbutidoAbreSheetAoVivo() {
        let s = session(pane: "main\t%3")
        let entry = liveEntry(for: s, target: "main\t%3")
        let target = SessionNavigationLogic.deepLink(session: s, tmuxEntry: entry, embedded: false, pathTopID: nil)
        XCTAssertEqual(target, .liveSheet(entry))
    }

    // MARK: resolveDeepLink — sessão SEM tmuxTarget

    func testDeepLinkSessaoSemTmuxTargetEmbutidoViraSelecaoDeSessao() {
        let s = session(pane: nil)
        let target = SessionNavigationLogic.deepLink(session: s, tmuxEntry: nil, embedded: true, pathTopID: nil)
        XCTAssertEqual(target, .selection(.session(s)))
    }

    func testDeepLinkSessaoSemTmuxTargetNaoEmbutidoEmpurraNaPilha() {
        let s = session(pane: nil)
        let target = SessionNavigationLogic.deepLink(session: s, tmuxEntry: nil, embedded: false, pathTopID: nil)
        XCTAssertEqual(target, .push(s))
    }

    func testDeepLinkSessaoSemTmuxTargetNaoEmbutidoJaNoTopoNaoFazNada() {
        let s = session(id: "s1", pane: nil)
        let target = SessionNavigationLogic.deepLink(session: s, tmuxEntry: nil, embedded: false, pathTopID: "s1")
        XCTAssertNil(target)
    }

    // MARK: go(to:) — usado por criar/adotar sessão (entrada "ao vivo" nova)

    func testGoToEmbutidoSempreSelecionaSessaoMesmoComTmuxTarget() {
        // go(to:) não olha tmuxTarget (diferente de resolveDeepLink) — sessão
        // recém-criada/adotada sempre abre o detalhe normal no iPad.
        let s = session(pane: "main\t%3")
        let target = SessionNavigationLogic.goTo(session: s, embedded: true, pathTopID: nil)
        XCTAssertEqual(target, .selection(.session(s)))
    }

    func testGoToNaoEmbutidoEmpurraNaPilha() {
        let s = session(pane: nil)
        let target = SessionNavigationLogic.goTo(session: s, embedded: false, pathTopID: nil)
        XCTAssertEqual(target, .push(s))
    }

    func testGoToNaoEmbutidoJaNoTopoNaoFazNada() {
        let s = session(id: "s1", pane: nil)
        let target = SessionNavigationLogic.goTo(session: s, embedded: false, pathTopID: "s1")
        XCTAssertNil(target)
    }

    // MARK: vivasPorChave — dicionário de reconciliação das abas (G6)
    //
    // Cobre o achado crítico #2 da revisão adversarial (12/08/2026): o
    // dicionário que alimenta `OpenTabs.reconciliar(vivas:)` só tinha chaves
    // `.live`, então toda aba `.chat` morria no primeiro reconciliar mesmo
    // com a sessão viva no registry.

    func testVivasPorChaveIncluiChaveDeChatDeSessaoViva() {
        let s = session(id: "s1", pane: nil)
        let vivas = SessionNavigationLogic.vivasPorChave(live: [], sessions: [s])
        XCTAssertEqual(vivas[.para(.session(s))], .sessao(.session(s)))
    }

    func testVivasPorChaveNaoIncluiSessaoQueSaiuDaLista() {
        // A sessão existe (poderia estar numa aba aberta antes), mas não é
        // passada em `sessions` — como se tivesse saído do registry. A chave
        // dela não deve aparecer: é isso que faz `OpenTabs.reconciliar`
        // marcar a aba como `.morta`.
        let s = session(id: "s1", pane: nil)
        let vivas = SessionNavigationLogic.vivasPorChave(live: [], sessions: [])
        XCTAssertNil(vivas[.para(.session(s))])
    }

    func testVivasPorChaveIncluiChaveAoVivoComoAntes() {
        let s = session(pane: "main\t%3")
        let entry = liveEntry(for: s, target: "main\t%3")
        let vivas = SessionNavigationLogic.vivasPorChave(live: [entry], sessions: [])
        XCTAssertEqual(vivas[.para(.live(entry))], .sessao(.live(entry)))
    }

    func testVivasPorChaveColisaoDeChaveAoVivoNaoEstouraEMantemOPrimeiro() {
        // Dois panes podem produzir a MESMA chave (mesma máquina + mesmo alvo
        // tmux) — o `Dictionary(_:uniquingKeysWith:)` original existia por
        // isso. A função nova preserva "o primeiro ganha".
        let s = session(pane: "main\t%3")
        let primeiro = liveEntry(for: s, target: "main\t%3")
        let segundo = LiveEntry(machine: s.machine,
                                session: DiscoveredSession(id: "main\t%3", cwd: "/outra", title: "outro"))
        let vivas = SessionNavigationLogic.vivasPorChave(live: [primeiro, segundo], sessions: [])
        XCTAssertEqual(vivas.count, 1)
        XCTAssertEqual(vivas[.para(.live(primeiro))], .sessao(.live(primeiro)))
    }

    func testOpenTabsReconciliarComVivasPorChaveMantemAbaDeChatVivaAberta() {
        // É este o bug: alimentado pelo dicionário incompleto (só `.live`),
        // `OpenTabs.reconciliar` marcava esta aba como `.morta` mesmo com a
        // sessão presente em `sessions`. Com `vivasPorChave`, ela sobrevive.
        let s = session(id: "s1", pane: nil)
        var tabs = OpenTabs()
        let chave = ChaveDeAba.para(.session(s))
        tabs.abrir(chave: chave, titulo: "t", conteudo: .sessao(.session(s)))

        let vivas = SessionNavigationLogic.vivasPorChave(live: [], sessions: [s])
        tabs.reconciliar(vivas: vivas)

        XCTAssertEqual(tabs.aba(chave)?.conteudo, .sessao(.session(s)))
    }
}
