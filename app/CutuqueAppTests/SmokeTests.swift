import XCTest
@testable import CutuqueApp

/// Prova que o alvo de teste existe, roda e enxerga o módulo do app.
final class SmokeTests: XCTestCase {
    func testColunasDoBoardEstaoNaOrdemDoFluxo() {
        XCTAssertEqual(
            BoardColumn.allCases.map(\.rawValue),
            ["a_fazer", "em_progresso", "feito", "em_revisao", "concluido"]
        )
    }
}
