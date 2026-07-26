import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre o contrato mínimo, testável fora do simulador, da Task 7: a raiz do
/// iPad é uma NavigationSplitView nova (`RootSplitView`), mas o `ArchiveView`
/// sem argumento continua funcionando exatamente como no iPhone hoje — é o
/// requisito "o iPhone não pode regredir". O resto da task (a própria
/// NavigationSplitView, a troca de raiz por idiom, girar sem derrubar o
/// espelho) é estrutura de SwiftUI sem lógica pura para isolar em XCTest; o
/// critério de aceite real é o passo manual no simulador (Step 5 do brief).
final class RootSplitViewTests: XCTestCase {

    /// `ArchiveView()` sem argumento precisa continuar embutindo `embedded: false`
    /// e `selection: nil` por padrão — senão toda tela que já chama
    /// `ArchiveView()` no iPhone muda de comportamento sem querer.
    func testArchiveViewSemArgumentoContinuaComoNoIPhone() {
        let view = ArchiveView()
        XCTAssertFalse(view.embedded)
        XCTAssertNil(view.selection)
    }
}
