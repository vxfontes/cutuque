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
