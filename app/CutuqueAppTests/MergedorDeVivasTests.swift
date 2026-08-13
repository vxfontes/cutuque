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

    /// Máquina que some do `/targets` não deixa fantasma na lista: sem isto,
    /// uma máquina desligada e removida do cadastro continuaria aparecendo com
    /// a última leitura ao vivo que teve, para sempre.
    func testDefinirOrdemRemoveMaquinaQueSaiuDoTargets() {
        var m = MergedorDeVivas(ordem: ["macbook", "macmini"])
        _ = m.fundir(maquina: "macbook", entradas: [entrada("macbook", "mike")])
        _ = m.fundir(maquina: "macmini", entradas: [entrada("macmini", "aux")])
        m.definirOrdem(["macmini"])
        XCTAssertEqual(m.entradas.map(\.machine), ["macmini"])
    }
}
