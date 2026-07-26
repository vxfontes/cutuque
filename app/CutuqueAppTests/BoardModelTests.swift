import XCTest
@testable import CutuqueApp

/// `BoardModel.task(id:)` é a única parte de `drop()` (Task 14) que não fala
/// com a rede — o resto (o `try await api...` + `load()`) segue o mesmo
/// padrão sem teste unitário dos demais métodos de `BoardModel` (`move`,
/// `markEncalhada`, `comment`...), verificado só manualmente (aceite).
@MainActor
final class BoardModelTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String, column: String = "a_fazer") -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"\(column)","group":"g","session":"s"}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    func testAchaOCardPeloId() {
        let model = BoardModel()
        model.tasks = [task(id: "a"), task(id: "b")]
        XCTAssertEqual(model.task(id: "b")?.id, "b")
    }

    func testIdInexistenteRetornaNil() {
        let model = BoardModel()
        model.tasks = [task(id: "a")]
        XCTAssertNil(model.task(id: "zzz"))
    }
}
