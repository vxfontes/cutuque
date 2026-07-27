import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre o contrato mínimo, testável fora do simulador, da Task 13: colunas
/// lado a lado no iPad e o detalhe do card virando inspector. A Task 13
/// também punha os filtros numa coluna do meio (`BoardFilterList`) — isso foi
/// desfeito depois, a pedido da Vanessa: os filtros voltaram pro topo do
/// kanban, nas duas orientações. O resto (GeometryReader, `.inspector`,
/// paginação condicional) é
/// estrutura de SwiftUI sem lógica pura pra isolar em XCTest; o critério de
/// aceite real é o passo manual no simulador (Step 8 do brief).
///
/// A decisão "iPad vs. iPhone" que discrimina busca dupla/paginação/FilterBar
/// (achados Important 1 e 2 da rodada de correção 1) foi extraída como função
/// pura — `BoardLayout.isPad(_:)` — e está coberta em `BoardMoveLogicTests`,
/// não aqui.
@MainActor
final class BoardViewIPadTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String = "x") -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"a_fazer","group":"g","session":"s"}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    /// Dentro de um `.inspector`, `@Environment(\.dismiss)` não fecha nada —
    /// `onClose` é a saída alternativa. Nil precisa continuar significando
    /// "sheet, o `dismiss` do ambiente resolve", como hoje (sheet do iPhone e
    /// sheet do arquivo continuam chamando sem `onClose`).
    func testBoardTaskDetailViewOnCloseDefaultNilContinuaComoSheet() {
        let view = BoardTaskDetailView(task: task(), model: BoardModel())
        XCTAssertNil(view.onClose)
    }
}
