import XCTest
@testable import CutuqueApp

/// D12: nome de grupo e de sessão é barrado NO TECLADO, não num erro criptográfico
/// depois. O tmux usa ":" e "." como separador de alvo (sessão:janela.pane) e o grupo
/// viaja num caminho de socket — nome fora do alfabeto produziria alvo ambíguo.
final class NomeTmuxTests: XCTestCase {

    func testAceitaLetrasNumerosHifenEUnderscore() {
        XCTAssertTrue(NomeTmux.valido("defender"))
        XCTAssertTrue(NomeTmux.valido("mike-aux_2"))
        XCTAssertTrue(NomeTmux.valido("A1"))
    }

    func testRecusaVazioESeparadoresDoTmux() {
        XCTAssertFalse(NomeTmux.valido(""))
        XCTAssertFalse(NomeTmux.valido("mike.aux"))
        XCTAssertFalse(NomeTmux.valido("defender:1"))
        XCTAssertFalse(NomeTmux.valido("mike aux"))
        XCTAssertFalse(NomeTmux.valido("../etc"))
        XCTAssertFalse(NomeTmux.valido("açaí"))
    }

    /// O campo filtra enquanto digita — é isso que "barrado no teclado" quer dizer.
    func testFiltrandoRemoveOInvalidoEPreservaOResto() {
        XCTAssertEqual(NomeTmux.filtrando("mike.aux"), "mikeaux")
        XCTAssertEqual(NomeTmux.filtrando("de fen:der"), "defender")
        XCTAssertEqual(NomeTmux.filtrando("mike-aux_2"), "mike-aux_2")
        XCTAssertEqual(NomeTmux.filtrando(""), "")
    }
}
