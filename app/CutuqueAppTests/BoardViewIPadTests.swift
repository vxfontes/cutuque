import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre o contrato mínimo, testável fora do simulador, da Task 13: colunas
/// lado a lado no iPad, filtros na coluna do meio e o detalhe do card virando
/// inspector. O resto (GeometryReader, `.inspector`, paginação condicional) é
/// estrutura de SwiftUI sem lógica pura pra isolar em XCTest; o critério de
/// aceite real é o passo manual no simulador (Step 8 do brief).
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

    /// `FilterBar`/`FilterMenu` viram não-private pra o `BoardFilterList`
    /// (coluna do meio do iPad, arquivo separado) reusar a linha de filtro —
    /// aqui simulamos o mesmo tipo de acesso cross-file que ele faz.
    func testFilterBarEFilterMenuSaoAcessiveisForaDoArquivo() {
        let model = BoardModel()
        _ = FilterBar(model: model)
        _ = FilterMenu(label: "Ambiente", selection: .constant("all"), options: [])
    }
}
