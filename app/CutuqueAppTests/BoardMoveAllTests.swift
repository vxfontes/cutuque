import XCTest
@testable import CutuqueApp

/// "Mover tudo": o botão no topo da coluna que despeja a coluna inteira em
/// outra. A decisão de QUEM entra na conta mora no hub (`naFaixa`, em
/// `hub/internal/server/board_http.go`) e é espelhada aqui e no dashboard —
/// estes testes são o que impede as três cópias de divergirem em silêncio.
@MainActor
final class BoardMoveAllTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String, column: String = "a_fazer",
                      encalhada: Bool = false, group: String = "macbook") -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"\(column)","group":"\(group)",
         "session":"s","encalhada":\(encalhada)}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    // MARK: - Quem está na faixa (mesma regra do hub)

    func testCardContaNaFaixaDaPropriaColuna() {
        XCTAssertTrue(BoardMoveLogic.naFaixa(task(id: "a", column: "em_progresso"),
                                             .column(.emProgresso)))
        XCTAssertFalse(BoardMoveLogic.naFaixa(task(id: "a", column: "em_progresso"),
                                              .column(.feito)))
    }

    /// Card encalhado tem `column == "a_fazer"`, mas a coluna "A fazer" não o
    /// mostra — ele vive na faixa Encalhadas. Mover "A fazer" não pode levá-lo.
    func testEncalhadoNaoContaEmAFazer() {
        XCTAssertFalse(BoardMoveLogic.naFaixa(task(id: "a", encalhada: true), .column(.aFazer)))
    }

    func testEncalhadoContaNaFaixaEncalhadas() {
        XCTAssertTrue(BoardMoveLogic.naFaixa(task(id: "a", encalhada: true), .encalhadas))
        XCTAssertFalse(BoardMoveLogic.naFaixa(task(id: "a"), .encalhadas))
    }

    // MARK: - Destinos oferecidos

    func testDestinosNaoIncluemAPropriaColuna() {
        let destinos = BoardMoveLogic.destinos(from: .column(.feito))
        XCTAssertEqual(destinos.count, BoardColumn.allCases.count - 1)
        XCTAssertFalse(destinos.contains(.feito))
    }

    /// Encalhadas é origem, nunca destino (decisão da Vanessa) — então de lá
    /// saem as cinco colunas.
    func testDeEncalhadasTodasAsColunasSaoDestino() {
        XCTAssertEqual(BoardMoveLogic.destinos(from: .encalhadas), BoardColumn.allCases)
    }

    // MARK: - Caminho e rótulo da faixa

    func testCaminhoDaFaixaEOQueOHubEspera() {
        XCTAssertEqual(BoardMoveLogic.caminho(.column(.emRevisao)), "em_revisao")
        XCTAssertEqual(BoardMoveLogic.caminho(.encalhadas), "encalhadas")
    }

    func testRotuloDaFaixa() {
        XCTAssertEqual(BoardMoveLogic.rotulo(.column(.emProgresso)), "Em progresso")
        XCTAssertEqual(BoardMoveLogic.rotulo(.encalhadas), "Encalhadas")
    }

    // MARK: - Textos do popup

    func testTituloDizDeOndeSai() {
        XCTAssertEqual(MoveAllPrompt.title(.column(.emProgresso)), "Mover tudo de Em progresso?")
    }

    func testMensagemDizQuantosEParaOnde() {
        XCTAssertEqual(MoveAllPrompt.message(total: 3, visivel: 3,
                                             from: .column(.emProgresso), to: .feito),
                       "3 cards de Em progresso vão para Feito.")
    }

    /// Um card só concorda no singular ("vai", não "vão").
    func testUmCardNoSingular() {
        XCTAssertEqual(MoveAllPrompt.message(total: 1, visivel: 1,
                                             from: .encalhadas, to: .emProgresso),
                       "1 card de Encalhadas vai para Em progresso.")
    }

    /// O hub move a coluna INTEIRA — o filtro da barra é só da tela. Quando os
    /// dois números divergem, a confirmação avisa antes de mover.
    func testAvisaQuandoOsFiltrosEscondemCards() {
        let m = MoveAllPrompt.message(total: 4, visivel: 3,
                                      from: .column(.emProgresso), to: .feito)
        XCTAssertTrue(m.contains("4 cards"), m)
        XCTAssertTrue(m.contains("escondem 1"), m)
        XCTAssertTrue(m.contains("coluna inteira"), m)
    }

    // MARK: - Contagem real (a que o hub vai mover), ignorando os filtros

    func testTotalDaFaixaIgnoraOsFiltrosDaBarra() {
        let model = BoardModel()
        model.tasks = [task(id: "a", column: "em_progresso", group: "macbook"),
                       task(id: "b", column: "em_progresso", group: "windows"),
                       task(id: "c", column: "feito", group: "macbook")]
        model.filterGroup = "macbook"
        XCTAssertEqual(model.inColumn(.emProgresso).count, 1, "a tela respeita o filtro")
        XCTAssertEqual(model.totalNaFaixa(.column(.emProgresso)), 2, "o hub move a coluna inteira")
    }

    func testTotalDaFaixaEncalhadas() {
        let model = BoardModel()
        model.tasks = [task(id: "a", encalhada: true, group: "windows"),
                       task(id: "b", encalhada: true, group: "macbook"),
                       task(id: "c", column: "feito")]
        model.filterGroup = "macbook"
        XCTAssertEqual(model.totalNaFaixa(.encalhadas), 2)
    }
}
