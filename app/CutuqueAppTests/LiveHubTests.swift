import XCTest
@testable import CutuqueApp

/// Roteamento da conexão única. É a parte que decide QUEM recebe o quê, extraída
/// como função pura porque a conexão em si não se testa sem hub de verdade.
final class LiveHubTests: XCTestCase {

    /// `Session` só tem `init(from:)` — decodifica um JSON mínimo pelo mesmo
    /// `JSONDecoder.cutuque` usado pelo `APIClient` (mesma convenção de
    /// `SessionDetailPaneLogicTests.makeSession`).
    private func sessao(_ id: String) -> Session {
        let json = """
        {
            "id": "\(id)", "machine": "macbook", "agent": "claude",
            "title": "\(id)", "state": "idle",
            "createdAt": "2026-07-26T12:00:00Z", "updatedAt": "2026-07-26T12:00:00Z"
        }
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    func testAtualizacaoDeSessaoVaiSoParaQuemEhDaquelaSessao() {
        let destinos = LiveHubRouting.destinatarios(de: .sessionUpdated(sessao("s1")),
                                                    inscritos: ["s1", "s2"])
        XCTAssertEqual(destinos, ["s1"])
    }

    func testChunkVaiSoParaASessaoDele() {
        let destinos = LiveHubRouting.destinatarios(de: .outputChunk(sessionID: "s2", kind: .tool, text: "oi"),
                                                    inscritos: ["s1", "s2"])
        XCTAssertEqual(destinos, ["s2"])
    }

    func testMensagemDeSessaoQueNinguemAssinaNaoVaiParaNinguem() {
        let destinos = LiveHubRouting.destinatarios(de: .outputChunk(sessionID: "s9", kind: .tool, text: "oi"),
                                                    inscritos: ["s1", "s2"])
        XCTAssertTrue(destinos.isEmpty)
    }

    /// Snapshot é do estado inteiro: interessa a todos, e cada um se acha nele
    /// (é o que o `SessionDetailViewModel` já faz em `:80-84`).
    func testSnapshotVaiParaTodos() {
        let destinos = LiveHubRouting.destinatarios(de: .snapshot([sessao("s1")]),
                                                    inscritos: ["s1", "s2"])
        XCTAssertEqual(destinos, ["s1", "s2"])
    }

    /// A regra que evita o bug silencioso: tipo de mensagem que este roteador não
    /// conhece vai para TODOS, e quem recebe filtra — igual ao `default: break`
    /// que o ViewModel já tem. Roteador que descarta o desconhecido faria uma
    /// mensagem nova do hub simplesmente nunca chegar, sem erro nenhum.
    ///
    /// Um caso por membro do enum além de `sessionUpdated` e `outputChunk`:
    /// `snapshot` e `sessionRemoved` (`grep -n "enum WSMessage" -A 20
    /// app/CutuqueApp/Models.swift`).
    func testCadaOutroTipoDeMensagemVaiParaTodos() {
        for mensagem in outrosTiposDeMensagem {
            XCTAssertEqual(LiveHubRouting.destinatarios(de: mensagem, inscritos: ["s1", "s2"]),
                           ["s1", "s2"], "\(mensagem)")
        }
    }

    private var outrosTiposDeMensagem: [WSMessage] {
        [.snapshot([]), .sessionRemoved(sessionID: "s3")]
    }
}
