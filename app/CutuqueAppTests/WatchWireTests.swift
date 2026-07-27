import XCTest
@testable import CutuqueApp

/// Cobre o contrato iPhone↔Watch (`SharedWatch/WatchWire.swift`) e a máquina de
/// estados da tela do relógio.
///
/// Por que isto merece teste: no pulso não há como investigar nada. A tela
/// dizia "Tudo em dia" em três situações diferentes — nunca carregou, o pedido
/// falhou, e não há nada mesmo — e as duas primeiras eram indistinguíveis de
/// "está tudo certo". Um agente parado esperando aprovação some da sua vista.
///
/// Estes testes são o único lugar onde esse código roda fora do relógio: o alvo
/// `CutuqueWatch` é watchOS e a suíte é iOS, então só o que mora em
/// `SharedWatch/` (compilado nos dois) chega aqui.
final class WatchWireTests: XCTestCase {

    // MARK: - Ida e volta pelo dicionário

    func testSessaoSobreviveAoRoundTrip() {
        let original = WatchSession(
            id: "s-1",
            title: "loja-acme",
            machine: "macbook",
            agent: "claude",
            prompt: "posso rodar os testes?",
            hasPane: true,
            isExternal: false,
            questions: [
                WatchQuestion(question: "Qual banco?", header: "Banco", multiSelect: false,
                              options: [WatchQuestionOption(label: "Postgres", description: "o de sempre"),
                                        WatchQuestionOption(label: "SQLite")])
            ])

        let volta = WatchSession(wire: original.wire)
        XCTAssertEqual(volta, original)
    }

    func testRespostaCompletaSobreviveAoRoundTrip() {
        let reply = WatchNeedsYouReply(
            sessions: [WatchSession(id: "a", title: "api", machine: "desktop", agent: "codex")],
            overview: WatchOverview(running: 3, done: 1, error: 0, idle: 2))

        let volta = WatchNeedsYouReply(wire: reply.wire)
        XCTAssertEqual(volta, reply)
    }

    /// O `sendMessage` do WatchConnectivity só aceita property list. Se algum
    /// campo virar um tipo Swift que não seja plist, a mensagem falha em runtime
    /// no relógio, sem erro de compilação.
    func testDicionarioEhPropertyListValida() {
        let reply = WatchNeedsYouReply(
            sessions: [WatchSession(id: "a", title: "api", prompt: "ok?",
                                    questions: [WatchQuestion(question: "q", options: [WatchQuestionOption(label: "l")])])],
            overview: WatchOverview(running: 1))
        XCTAssertTrue(PropertyListSerialization.propertyList(reply.wire, isValidFor: .binary))
    }

    // MARK: - Resposta malformada ≠ lista vazia

    /// O bug original: o iPhone respondia algo sem `sessions` (erro, ou lixo) e
    /// o relógio lia como lista vazia → "Tudo em dia".
    func testRespostaSemSessionsEhIlegivel() {
        XCTAssertNil(WatchNeedsYouReply(wire: [:]))
        XCTAssertNil(WatchNeedsYouReply(wire: ["error": "o iPhone não alcançou o hub"]))
        XCTAssertNil(WatchNeedsYouReply(wire: ["ok": true]))
    }

    func testListaVaziaLegitimaEhLida() {
        let reply = WatchNeedsYouReply(wire: ["sessions": [[String: Any]]()])
        XCTAssertNotNil(reply)
        XCTAssertEqual(reply?.sessions, [])
    }

    /// Entrada sem `id` não dá pra aprovar nem negar — vira linha morta.
    func testSessaoSemIdEhDescartada() {
        let reply = WatchNeedsYouReply(wire: ["sessions": [["title": "sem id"], ["id": "ok", "title": "boa"]]])
        XCTAssertEqual(reply?.sessions.map(\.id), ["ok"])
    }

    func testCamposAusentesCaemEmDefaults() {
        let s = WatchSession(wire: ["id": "x"])
        XCTAssertEqual(s?.title, "sessão")
        XCTAssertEqual(s?.prompt, "")
        XCTAssertEqual(s?.hasPane, false)
        XCTAssertEqual(s?.isExternal, false)
        XCTAssertEqual(s?.questions, [])
    }

    // MARK: - Panorama

    func testOrigemJuntaMaquinaEAgente() {
        XCTAssertEqual(WatchSession(id: "a", title: "t", machine: "macbook", agent: "claude").origin, "macbook · claude")
        XCTAssertEqual(WatchSession(id: "a", title: "t", machine: "macbook").origin, "macbook")
        XCTAssertEqual(WatchSession(id: "a", title: "t").origin, "")
    }

    func testResumoSingularEPlural() {
        XCTAssertEqual(WatchOverview(running: 1).summary, "1 rodando")
        XCTAssertEqual(WatchOverview(running: 3).summary, "3 rodando")
        XCTAssertEqual(WatchOverview(done: 1).summary, "1 concluída")
        XCTAssertEqual(WatchOverview(done: 2).summary, "2 concluídas")
        XCTAssertEqual(WatchOverview(error: 1).summary, "1 falhou")
        XCTAssertEqual(WatchOverview(error: 2).summary, "2 falharam")
        XCTAssertEqual(WatchOverview(idle: 1).summary, "1 ociosa")
    }

    /// O mostrador é estreito: no máximo dois itens, os mais urgentes.
    func testResumoLimitaADoisItensEmOrdemDeUrgencia() {
        let cheio = WatchOverview(running: 2, done: 5, error: 1, idle: 9)
        XCTAssertEqual(cheio.summary, "2 rodando · 1 falhou")
        XCTAssertEqual(WatchOverview(done: 5, idle: 9).summary, "5 concluídas · 9 ociosas")
    }

    func testResumoVazio() {
        XCTAssertEqual(WatchOverview().summary, "")
        XCTAssertTrue(WatchOverview().isEmpty)
        XCTAssertFalse(WatchOverview(idle: 1).isEmpty)
    }

    // MARK: - Máquina de estados da tela

    private func tela(_ phase: WatchLoadPhase,
                      reachable: Bool = true,
                      sessions: [WatchSession] = [],
                      overview: WatchOverview = WatchOverview()) -> WatchScreen {
        WatchScreenState.screen(phase: phase, reachable: reachable, sessions: sessions, overview: overview)
    }

    private let uma = [WatchSession(id: "a", title: "api")]

    /// O cerne do conserto: cada situação tem a sua tela.
    func testCadaSituacaoTemSuaTela() {
        XCTAssertEqual(tela(.inicial), .carregando)
        XCTAssertEqual(tela(.falhou("o iPhone não respondeu")), .falhou("o iPhone não respondeu"))
        XCTAssertEqual(tela(.carregado), .tudoEmDia(WatchOverview()))
        XCTAssertEqual(tela(.carregado, sessions: uma), .lista(uma))
    }

    /// "Tudo em dia" só quando o iPhone REALMENTE respondeu que não há nada.
    func testTudoEmDiaSoDepoisDeRespostaValida() {
        for phase: WatchLoadPhase in [.inicial, .falhou("x")] {
            if case .tudoEmDia = tela(phase) {
                XCTFail("\(phase) não pode virar 'Tudo em dia'")
            }
        }
    }

    /// Fora de alcance é mais acionável ("chegue perto do iPhone") que o texto
    /// do erro, então ganha do `.falhou`.
    func testForaDeAlcanceTemPrecedenciaSobreOErro() {
        XCTAssertEqual(tela(.falhou("o iPhone não respondeu"), reachable: false), .foraDeAlcance)
        XCTAssertEqual(tela(.inicial, reachable: false), .foraDeAlcance)
    }

    /// Uma lista já carregada não some porque o refresh seguinte falhou ou o
    /// iPhone se afastou — o que está ali ainda dá pra aprovar, e o rodapé
    /// conta a idade do dado.
    func testListaCarregadaSobreviveAFalhaEAoAfastamento() {
        XCTAssertEqual(tela(.falhou("timeout"), sessions: uma), .lista(uma))
        XCTAssertEqual(tela(.inicial, reachable: false, sessions: uma), .lista(uma))
    }

    /// O relógio pode desconectar logo depois de uma resposta boa. Se a
    /// resposta trouxe panorama, ele continua valendo — vira dado velho, não
    /// dado errado.
    func testPanoramaSobreviveAoAfastamento() {
        XCTAssertEqual(tela(.carregado, reachable: false, overview: WatchOverview(running: 2)),
                       .tudoEmDia(WatchOverview(running: 2)))
        XCTAssertEqual(tela(.carregado, reachable: false), .foraDeAlcance)
    }

    /// Um refresh em voo NÃO tem tela própria: "Procurando…" é só a primeira
    /// carga. Trocar a lista por um spinner a cada dez segundos de auto-refresh
    /// pisca mais do que informa — a idade no rodapé é quem conta isso.
    func testRefreshDeFundoNaoTrocaATela() {
        XCTAssertEqual(tela(.carregado, sessions: uma), .lista(uma))
        XCTAssertEqual(tela(.carregado, overview: WatchOverview(running: 1)),
                       .tudoEmDia(WatchOverview(running: 1)))
    }

    // MARK: - Rodapé

    func testRodapeMostraOErroQuandoHaUm() {
        XCTAssertEqual(WatchScreenState.footer(erro: "o iPhone não respondeu", idade: 3), "o iPhone não respondeu")
    }

    func testRodapeMostraIdadeQuandoNaoHaErro() {
        XCTAssertEqual(WatchScreenState.footer(erro: nil, idade: 90), "atualizado há 1 min")
        XCTAssertNil(WatchScreenState.footer(erro: nil, idade: nil))
    }

    func testIdadeEmLinguagemDeGente() {
        XCTAssertEqual(WatchScreenState.ago(0), "agora")
        XCTAssertEqual(WatchScreenState.ago(4.9), "agora")
        XCTAssertEqual(WatchScreenState.ago(12), "há 12 s")
        XCTAssertEqual(WatchScreenState.ago(59), "há 59 s")
        XCTAssertEqual(WatchScreenState.ago(60), "há 1 min")
        XCTAssertEqual(WatchScreenState.ago(3599), "há 59 min")
        XCTAssertEqual(WatchScreenState.ago(7200), "há 2 h")
        // Relógio pra trás não pode virar "há -3 s".
        XCTAssertEqual(WatchScreenState.ago(-3), "agora")
    }
}

// MARK: - Lado do iPhone

/// Cobre `PhoneWatchRelay.needsYouReply(from:)` — a tradução da lista completa
/// do hub no que cabe no pulso. É o outro lado do contrato acima.
final class PhoneWatchRelayPayloadTests: XCTestCase {

    /// `Session` só tem `init(from:)`; monta pelo mesmo decoder do `APIClient`.
    private func session(_ id: String, state: String, prompt: String? = nil,
                         machine: String = "macbook", agent: String = "claude",
                         external: Bool = false, pane: String? = nil) -> Session {
        let promptField = prompt.map { "\"pending_prompt\": \"\($0)\"," } ?? ""
        let paneField = pane.map { "\"pane\": \"\($0)\"," } ?? ""
        let json = """
        {
            "id": "\(id)", "machine": "\(machine)", "agent": "\(agent)",
            "title": "\(id)", "state": "\(state)",
            "external": \(external), \(promptField) \(paneField)
            "created_at": "2026-07-26T12:00:00Z", "updated_at": "2026-07-26T12:00:00Z"
        }
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    /// Só needs_you vira linha na lista; o resto vira contagem.
    func testSeparaNeedsYouDoPanorama() {
        let reply = PhoneWatchRelay.needsYouReply(from: [
            session("a", state: "needs_you"),
            session("b", state: "running"),
            session("c", state: "running"),
            session("d", state: "done"),
            session("e", state: "error"),
            session("f", state: "idle"),
        ])

        XCTAssertEqual(reply.sessions.map(\.id), ["a"])
        XCTAssertEqual(reply.overview, WatchOverview(running: 2, done: 1, error: 1, idle: 1))
    }

    /// A contagem NÃO inclui as que precisam de você — elas já estão na lista,
    /// e "Tudo em dia · 1 rodando" com um pedido parado seria mentira.
    func testPanoramaNaoContaAsQuePrecisamDeVoce() {
        let reply = PhoneWatchRelay.needsYouReply(from: [
            session("a", state: "needs_you"),
            session("b", state: "needs_you"),
        ])
        XCTAssertEqual(reply.sessions.count, 2)
        XCTAssertTrue(reply.overview.isEmpty)
    }

    func testHubVazioNaoEhErro() {
        let reply = PhoneWatchRelay.needsYouReply(from: [])
        XCTAssertEqual(reply.sessions, [])
        XCTAssertTrue(reply.overview.isEmpty)
    }

    func testLevaMaquinaAgenteEPromptLimpo() {
        let reply = PhoneWatchRelay.needsYouReply(from: [
            session("a", state: "needs_you", prompt: "  posso rodar?  ", machine: "desktop", agent: "codex")
        ])
        let s = try! XCTUnwrap(reply.sessions.first)
        XCTAssertEqual(s.machine, "desktop")
        XCTAssertEqual(s.agent, "codex")
        XCTAssertEqual(s.prompt, "posso rodar?")
        XCTAssertEqual(s.origin, "desktop · codex")
    }

    /// `hasPane` decide se o pulso oferece aprovar/negar ou só responder por
    /// texto (sessão de tmux não tem gate no hub).
    func testHasPaneSaiDoAlvoTmux() {
        let comTmux = PhoneWatchRelay.needsYouReply(from: [session("a", state: "needs_you", pane: "sock\\t%1")])
        XCTAssertEqual(comTmux.sessions.first?.hasPane, true)
        let sem = PhoneWatchRelay.needsYouReply(from: [session("a", state: "needs_you")])
        XCTAssertEqual(sem.sessions.first?.hasPane, false)
    }

    /// Sessão externa é read-only no pulso (SEC-112) — a flag tem que chegar
    /// lá, senão o relógio oferece um "Aprovar" que não aprova nada.
    func testSessaoExternaChegaMarcada() {
        let reply = PhoneWatchRelay.needsYouReply(from: [session("a", state: "needs_you", external: true)])
        XCTAssertEqual(reply.sessions.first?.isExternal, true)
    }
}
