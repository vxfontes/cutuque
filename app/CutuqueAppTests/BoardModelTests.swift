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

    // MARK: - Popup "onde arquivar?"

    private func opts(last: Bool, pending: Int = 3) -> CloseOptions {
        let ultima = last
            ? #""last":{"label":"2026-W30","start":"2026-07-20","end":"2026-07-26","count":70},"#
            : ""
        let json = """
        {"current":{"label":"2026-W31","start":"2026-07-27","end":"2026-08-02","count":0},
         \(ultima)
         "pending":\(pending)}
        """
        return try! JSONDecoder().decode(CloseOptions.self, from: Data(json.utf8))
    }

    /// Sem semana anterior no arquivo não há escolha a fazer: é o confirmar de sempre.
    func testSemUltimaSemanaOPopupEOConfirmarDeSempre() {
        let o = opts(last: false)
        XCTAssertNil(o.last)
        XCTAssertEqual(CloseWeekPrompt.title(o), "Fechar a semana agora?")
        XCTAssertTrue(CloseWeekPrompt.message(o).contains("3 concluídos"))
    }

    /// Com semana anterior, a pergunta muda e os dois caminhos aparecem por extenso.
    func testComUltimaSemanaOferecerOsDoisCaminhos() {
        let o = opts(last: true)
        XCTAssertEqual(CloseWeekPrompt.title(o), "Onde arquivar?")
        XCTAssertEqual(CloseWeekPrompt.juntarLabel(o.last!), "Juntar em 20 – 26 de jul (70)")
        XCTAssertEqual(CloseWeekPrompt.novaLabel(o.current), "Criar semana nova (27 de jul – 2 de ago)")
    }

    /// Rede caída não pode travar o fechamento — sem opções, o texto genérico.
    func testSemOpcoesCaiNoTextoGenerico() {
        XCTAssertEqual(CloseWeekPrompt.title(nil), "Fechar a semana agora?")
        XCTAssertTrue(CloseWeekPrompt.message(nil).hasPrefix("Os cards concluídos"))
    }

    func testUmConcluidoNoSingular() {
        XCTAssertTrue(CloseWeekPrompt.message(opts(last: true, pending: 1)).hasPrefix("1 concluído "))
    }

    /// Fila vazia: "0 concluídos vão sair do board" não diz nada. O que importa
    /// é que fechar ainda marca encalhados — e a escolha de semana segue valendo.
    func testFilaVaziaExplicaOQueFecharAindaFaz() {
        let m = CloseWeekPrompt.message(opts(last: true, pending: 0))
        XCTAssertFalse(m.contains("0 concluídos"))
        XCTAssertTrue(m.contains("encalhados"))
        XCTAssertEqual(CloseWeekPrompt.title(opts(last: true, pending: 0)), "Onde arquivar?")
    }

    /// Semana que atravessa a virada do mês escreve os dois meses.
    func testIntervaloComDoisMeses() {
        XCTAssertEqual(WeekRangeFormat.text(start: "2026-07-27", end: "2026-08-02"),
                       "27 de jul – 2 de ago")
    }
}
