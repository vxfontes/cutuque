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

    /// O alvo Windows entra pelo nome curto `windows` (o mesmo de
    /// `CUTUQUE_SSH_TARGETS`) e precisa continuar caindo no ícone de PC —
    /// o `switch` casa por substring, não por nome exato.
    func testAlvoWindowsUsaIconeDePC() {
        XCTAssertEqual(machineSymbol("windows"), "pc")
        XCTAssertEqual(machineSymbol("Windows"), "pc")
    }
}
