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
    /// Atraso artificial em `tmuxList` — é o que dá uma janela para duas
    /// passadas de `refreshLive` se cruzarem no teste de reentrância. Sem ele o
    /// dublê responde na mesma volta e a corrida nunca acontece.
    var atrasoDeTmuxList: Duration?
    private(set) var chamouTmuxList = 0

    func sessions() async throws -> [Session] {
        if let erroEmSessions { throw erroEmSessions }
        return sessoesParaDevolver
    }
    func targets() async throws -> [String] { alvos }
    func tmuxList(machine: String) async -> [DiscoveredSession] {
        chamouTmuxList += 1
        if let atrasoDeTmuxList { try? await Task.sleep(for: atrasoDeTmuxList) }
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

    /// `Session` só tem `init(from:)` — decodifica um JSON mínimo pelo mesmo
    /// `JSONDecoder.cutuque` usado pelo `APIClient` (padrão de
    /// `SessionDetailPaneLogicTests.makeSession`).
    private func sessaoDeTeste(id: String) -> Session {
        let json = """
        {
            "id": "\(id)", "machine": "mac1", "agent": "claude-code",
            "title": "sessão de teste", "state": "running",
            "createdAt": "2026-07-26T12:00:00Z", "updatedAt": "2026-07-26T12:00:00Z"
        }
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    /// `DiscoveredSession` tem init direto (ver `Models.swift`) — usado para
    /// sintetizar uma entrada viva a partir de um pane do tmux.
    private func paneDeTeste(id: String) -> DiscoveredSession {
        DiscoveredSession(id: id, cwd: "/tmp", title: "cutuque")
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

    // MARK: reentrância de refreshLive

    /// [13/08/2026] O debounce de `MergedorDeVivas` ("2 leituras vazias
    /// SEGUIDAS antes de acreditar que a máquina esvaziou") só protege se as
    /// duas leituras vierem de duas passadas de ~15 s. `refreshLive` tem quatro
    /// chamadores independentes — o laço do polling, o pull-to-refresh, o
    /// callback de criar terminal e o app intent `.reload` — e `@MainActor` NÃO
    /// impede que dois `Task` entrem na mesma passada: serializa só o trecho
    /// síncrono entre `await`s. Sem a guarda de reentrância, um hiccup de rede
    /// mais um pull-to-refresh davam dois vazios em segundos e a aba VIVA
    /// virava "Sessão encerrada" — o bug que já custou duas rodadas de conserto.
    func testDuasPassadasConcorrentesContamUmaLeituraVaziaSo() async {
        let api = APIFalsa()
        api.alvos = ["macmini"]
        api.panesPorMaquina = ["macmini": [paneDeTeste(id: "sock\t%1")]]
        let m = modelo(api)
        await m.refreshLive()
        XCTAssertEqual(m.liveSessions.count, 1)

        // Hiccup: a máquina passa a responder vazio, e devagar o bastante para
        // as duas passadas se cruzarem.
        api.panesPorMaquina = ["macmini": []]
        api.atrasoDeTmuxList = .milliseconds(80)

        async let primeira: Void = m.refreshLive()                    // poll de fundo
        async let segunda: Void = m.refreshLive(mostrandoCarga: true)  // pull-to-refresh
        _ = await (primeira, segunda)

        XCTAssertEqual(m.liveSessions.count, 1,
                       "duas passadas cruzadas não podem valer como dois vazios seguidos")
        XCTAssertTrue(m.maquinasPendentes.isEmpty, "a linha de carregando tem de sumir ao fim")

        // E o debounce continua funcionando: a PRÓXIMA passada, essa sim
        // separada no tempo, é a segunda leitura vazia de verdade.
        api.atrasoDeTmuxList = nil
        await m.refreshLive()
        XCTAssertTrue(m.liveSessions.isEmpty, "2 vazios em passadas distintas é verdade, não hiccup")
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
