import XCTest
@testable import CutuqueApp

/// Fixtures — mesmo padrão de `MachineAppearanceTests`/`NavigationStateTests`
/// (`Machine`) e `NavigationStateTests` (`BoardTask`). Funções livres (não
/// métodos) de propósito: os closures de `AbasResolver` são `@escaping` numa
/// classe, e método de instância exigiria `self.` em cada uso.
private func maquinaDeTeste(nome: String) -> Machine {
    Machine(name: nome, dest: "vx@192.0.2.50", port: 22, source: "app",
            hostFingerprint: "SHA256:abc", host: "192.0.2.50", identity: "vx",
            os: "Darwin 24.5.0", theme: nil, icon: nil)
}

private func cardDeTeste(id: String, titulo: String) -> BoardTask {
    BoardTask(id: id, title: titulo, column: "concluido", group: "g", session: "s")
}

private func semanaDeTeste(label: String, tasks: [BoardTask]) -> ArchivedWeek {
    ArchivedWeek(label: label, start: "2026-07-06", end: "2026-07-12", tasks: tasks)
}

/// `AbasResolver` resolve as abas de máquina/arquivo restauradas do disco só
/// com a chave (ver `AbaPersistida`). Sem isto elas girariam `ProgressView`
/// para sempre. `AbasResolucao` é a parte pura (sem rede, sem View); os
/// testes com `store(...)` cobrem o `resolver(_:)` completo.
@MainActor
final class AbasResolverTests: XCTestCase {

    private let chaveNoDisco = "abasAbertas.v1"
    private var valorOriginal: Data?

    /// `OpenTabsStore()` escreve em `UserDefaults.standard` na mesma chave pra
    /// TODA instância — sem isto um teste vaza aba pro próximo.
    override func setUp() {
        super.setUp()
        valorOriginal = UserDefaults.standard.data(forKey: chaveNoDisco)
        UserDefaults.standard.removeObject(forKey: chaveNoDisco)
    }

    override func tearDown() {
        if let valorOriginal {
            UserDefaults.standard.set(valorOriginal, forKey: chaveNoDisco)
        } else {
            UserDefaults.standard.removeObject(forKey: chaveNoDisco)
        }
        super.tearDown()
    }

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
        // Esta asserção depende de `OpenTabs.conteudoInicial` fazer o Board
        // nascer `.board` (Task 2). Enquanto as duas tasks corriam em paralelo
        // ela viveu dentro de um `XCTExpectFailure`, removido no merge das duas
        // (12/08/2026): sem o Board resolvido de saída, `tiposPendentes`
        // devolveria `{.board, .maquina}` e o resolver iria ao hub buscar
        // máquina por causa de uma aba que nunca precisou de busca.
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

        // A metade de cima prova o resolver casando presença; esta prova a
        // ausência matando — e ela só passa porque `dependeDeAlgoVivo(.maquina)`
        // virou `true` na Task 2. Enquanto as duas corriam em paralelo esta
        // linha viveu dentro de um `XCTExpectFailure`, removido no merge
        // (12/08/2026). É o par que importa: sem a de cima, "morre" poderia ser
        // um resolver que não resolve nada.
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
