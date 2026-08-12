import XCTest
@testable import CutuqueApp

/// D9: um grupo é uma seção só, com as máquinas misturadas dentro. O caso que
/// motivou tudo: grupo "defender" com a sessão "mike" no macbook e "mikeaux" no
/// windows — antes eram duas seções ("defender · macbook", "defender · windows").
final class LivePaneAgrupamentoTests: XCTestCase {

    private func entrada(machine: String, socket: String, pane: String,
                         session: String) -> LiveEntry {
        LiveEntry(machine: machine,
                  session: DiscoveredSession(id: socket + "\t" + pane,
                                             cwd: "/Users/vanessa/dev/" + session,
                                             title: session))
    }

    func testGrupoDeMesmoNomeEmDuasMaquinasCaiNumaSecaoSo() {
        let grupos = LivePaneLogic.agrupadoPorGrupo([
            entrada(machine: "macbook", socket: "/tmp/tmux-501/defender", pane: "%1", session: "mike"),
            entrada(machine: "windows", socket: "/tmp/tmux-501/defender", pane: "%1", session: "mikeaux"),
        ])
        XCTAssertEqual(grupos.count, 1)
        XCTAssertEqual(grupos[0].grupo, "defender")
        XCTAssertEqual(grupos[0].entries.count, 2)
    }

    /// A parte que não é estética: "Encerrar server" é destrutivo e, num grupo com
    /// duas máquinas, uma entrada só seria ambígua — mataria a errada.
    func testUmaEntradaDeEncerrarServerPorMaquina() {
        let grupos = LivePaneLogic.agrupadoPorGrupo([
            entrada(machine: "macbook", socket: "/tmp/tmux-501/defender", pane: "%1", session: "mike"),
            entrada(machine: "macbook", socket: "/tmp/tmux-501/defender", pane: "%2", session: "mike2"),
            entrada(machine: "windows", socket: "/tmp/tmux-501/defender", pane: "%1", session: "mikeaux"),
        ])
        XCTAssertEqual(grupos[0].servers.map(\.machine), ["macbook", "windows"])
        XCTAssertEqual(grupos[0].servers.count, 2, "uma entrada por MÁQUINA, não por pane")
    }

    func testGruposDiferentesSeparamEOrdemEhEstavel() {
        let grupos = LivePaneLogic.agrupadoPorGrupo([
            entrada(machine: "macbook", socket: "/tmp/tmux-501/zima", pane: "%1", session: "a"),
            entrada(machine: "macbook", socket: "/tmp/tmux-501/atlas", pane: "%1", session: "b"),
        ])
        XCTAssertEqual(grupos.map(\.grupo), ["atlas", "zima"])
    }

    func testSocketEGrupoSaemDoAlvoComposto() {
        XCTAssertEqual(LivePaneLogic.socket(of: "/tmp/tmux-501/defender\t%3"), "/tmp/tmux-501/defender")
        XCTAssertEqual(LivePaneLogic.nomeDoGrupo("/tmp/tmux-501/defender"), "defender")
        // Alvo sem socket (servidor default) não pode derrubar o agrupamento.
        XCTAssertEqual(LivePaneLogic.socket(of: "%3"), "")
    }

    /// O menu do cabeçalho passa a ter uma entrada por máquina, e o rótulo tem de
    /// dizer QUAL — é ação destrutiva, e ambiguidade aqui mata o server errado.
    func testRotuloDeEncerrarNomeiaAMaquina() {
        let s = ServidorDoGrupo(machine: "macbook", socket: "/tmp/tmux-501/defender")
        XCTAssertEqual(LivePaneLogic.rotuloDeEncerrar(s), "Encerrar server no macbook")
    }
}
