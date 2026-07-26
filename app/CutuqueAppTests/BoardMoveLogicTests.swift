import XCTest
@testable import CutuqueApp

final class BoardMoveLogicTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String = "abc", column: String = "a_fazer",
                      encalhada: Bool = false, archived: Bool = false) -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"\(column)","group":"g","session":"s",
         "encalhada":\(encalhada),"archived":\(archived)}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    // MARK: plano

    func testCardArquivadoNaoSeMove() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .column(.feito)))
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .encalhadas))
    }

    func testSoltarNaPropriaColunaNaoFazNada() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(column: "feito"), target: .column(.feito)))
    }

    func testMoverParaOutraColunaEhUmaChamadaSo() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer"), target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testSairDeEncalhadasEhUmaChamadaSo() {
        // O hub limpa a flag sozinho no move (postgres.go:281).
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testEncalhadaVoltandoParaAFazerAindaEhUmMove() {
        // Mesma coluna, mas precisa limpar a flag — não pode virar no-op.
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.aFazer)),
                       .move(.aFazer))
    }

    func testMarcarComoEncalhada() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "em_progresso"), target: .encalhadas),
                       .markEncalhada)
    }

    func testJaEncalhadaNaoRemarca() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(encalhada: true), target: .encalhadas))
    }

    // MARK: aplicação otimista

    func testAplicarMoveTrocaAColunaELimpaAFlag() {
        let antes = [task(id: "a", column: "a_fazer", encalhada: true)]
        let depois = BoardMoveLogic.apply(.move(.feito), to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "feito")
        XCTAssertEqual(depois[0].isEncalhada, false)
    }

    func testAplicarEncalhadaForcaAFazer() {
        let antes = [task(id: "a", column: "em_revisao")]
        let depois = BoardMoveLogic.apply(.markEncalhada, to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "a_fazer")
        XCTAssertEqual(depois[0].isEncalhada, true)
    }

    func testAplicarNumIdInexistenteNaoMexeEmNada() {
        let antes = [task(id: "a")]
        XCTAssertEqual(BoardMoveLogic.apply(.move(.feito), to: antes, id: "zzz"), antes)
    }

    // MARK: teclado

    func testColunaAdjacente() {
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: 1), .emProgresso)
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .emProgresso, offset: -1), .aFazer)
    }

    func testColunaAdjacenteNaoDaVoltaNoBoard() {
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: -1))
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .concluido, offset: 1))
    }

    // MARK: largura de coluna

    func testNoIPhoneAColunaContinuaPaginando() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 393, columns: 5, isRegular: false),
                       393 * 0.86, accuracy: 0.01)
    }

    func testNoIPadAsColunasDividemALargura() {
        // 1366 - 7 gutters de 12 = 1282 / 6 = 213,7 → cai no piso de 260.
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 6, isRegular: true), 260)
    }

    func testColunaLargaQuandoSobraEspaco() {
        // 1366 - 4 gutters = 1318 / 3 = 439,3
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 3, isRegular: true),
                       439.33, accuracy: 0.1)
    }

    func testZeroColunasNaoDivideProZero() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 0, isRegular: true),
                       1366 * 0.86, accuracy: 0.01)
    }

    // MARK: idiom (Task 13, correção dos achados Important 1 e 2 da revisão)
    //
    // `horizontalSizeClass == .regular` NÃO é "iPad": iPhone Plus/Pro Max em
    // paisagem também reporta `.regular`. `BoardView` (raiz do iPhone dentro
    // do `RootTabView`) e a busca duplicada da coluna de detalhe (que
    // sobrescrevia em silêncio a busca de `BoardFilterList` no iPad) dependem
    // desta MESMA decisão — travando-a aqui, pura, sem hospedar view.

    func testIPhoneNuncaEhPadNenhumSizeClass() {
        // O idiom do iPhone é fixo (.phone) mesmo quando o size class medido é
        // .regular (Plus/Pro Max em paisagem) — é exatamente o caso que
        // regredia antes desta correção.
        XCTAssertFalse(BoardLayout.isPad(.phone))
    }

    func testIPadEhPad() {
        XCTAssertTrue(BoardLayout.isPad(.pad))
    }
}
