import XCTest
@testable import CutuqueApp

/// Cobre a lógica pura introduzida pela Task 11 (atalhos ⌘): o índice seguro
/// usado por ⌘1…⌘9 para escolher a sessão certa da lista sem estourar limites.
/// A cena `Commands` e o consumo do intent em `SessionListView` são fiação
/// SwiftUI sem oráculo de teste unitário neste projeto (spec: "não há UI
/// test") — a garantia deles vem da compilação e da checagem manual do brief.
final class SessionListViewAtalhosTests: XCTestCase {

    func testIndiceSeguroDentroDosLimitesRetornaOElemento() {
        let sessoes = ["a", "b", "c"]
        XCTAssertEqual(sessoes[safe: 0], "a")
        XCTAssertEqual(sessoes[safe: 2], "c")
    }

    func testIndiceSeguroForaDosLimitesRetornaNil() {
        // ⌘5 com só duas sessões na lista: nada acontece, sem crash.
        let sessoes = ["a", "b"]
        XCTAssertNil(sessoes[safe: 4])
    }

    func testIndiceSeguroNegativoRetornaNil() {
        let sessoes = ["a", "b", "c"]
        XCTAssertNil(sessoes[safe: -1])
    }

    func testIndiceSeguroEmListaVaziaRetornaNil() {
        let sessoes: [String] = []
        XCTAssertNil(sessoes[safe: 0])
    }
}
