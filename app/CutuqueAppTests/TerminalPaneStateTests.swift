import XCTest
@testable import CutuqueApp

/// O estado de três valores existe porque booleano não distinguia "troquei de aba"
/// de "fechei o terminal": o primeiro MANTÉM a largura fixada (voltar para a aba não
/// precisa de dois POSTs de resize), o segundo DEVOLVE.
final class TerminalPaneStateTests: XCTestCase {

    func testSoOAtivoFazPolling() {
        XCTAssertTrue(TerminalPaneState.ativo.fazPolling)
        XCTAssertFalse(TerminalPaneState.suspenso.fazPolling)
        XCTAssertFalse(TerminalPaneState.liberado.fazPolling)
    }

    func testDevolveLarguraSoAoEntrarEmLiberado() {
        XCTAssertTrue(TerminalPaneState.devolveLargura(de: .ativo, para: .liberado))
        XCTAssertTrue(TerminalPaneState.devolveLargura(de: .suspenso, para: .liberado))
        // Suspender é trocar de aba: a largura FICA, senão voltar para a aba
        // remediria e reenviaria o resize a cada ida e volta.
        XCTAssertFalse(TerminalPaneState.devolveLargura(de: .ativo, para: .suspenso))
        XCTAssertFalse(TerminalPaneState.devolveLargura(de: .suspenso, para: .ativo))
        // Já liberado não devolve de novo.
        XCTAssertFalse(TerminalPaneState.devolveLargura(de: .liberado, para: .liberado))
    }

    /// A armadilha do conserto: o `.task(id:)` do TerminalMirrorView só reentra
    /// quando a chave muda, e a chave de hoje é só "colunas x linhas". Trocar de
    /// estado sem trocar de medida não reentrava — o estado tem de estar na chave.
    func testAChaveDeResizeMudaComOEstado() {
        let ativo = TerminalResizeKey.chave(cols: 80, rows: 24, estado: .ativo)
        let liberado = TerminalResizeKey.chave(cols: 80, rows: 24, estado: .liberado)
        XCTAssertNotEqual(ativo, liberado)
        XCTAssertEqual(ativo, TerminalResizeKey.chave(cols: 80, rows: 24, estado: .ativo))
        XCTAssertNotEqual(ativo, TerminalResizeKey.chave(cols: 100, rows: 24, estado: .ativo))
    }

    func testChaveSemMedidaAindaDistingueEstado() {
        XCTAssertNotEqual(TerminalResizeKey.chave(cols: nil, rows: nil, estado: .ativo),
                          TerminalResizeKey.chave(cols: nil, rows: nil, estado: .liberado))
    }

    /// D7: sair do app devolve o pane ao normal no PC. `.inactive` NÃO conta — ele
    /// dispara em troca de app, Split View e central de notificações, e devolver
    /// largura ali faria o terminal remediar toda hora.
    func testCenaDeBackgroundDevolveLargura() {
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .background, estado: .ativo), .devolver)
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .background, estado: .suspenso), .devolver)
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .background, estado: .liberado), .nada)
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .active, estado: .ativo), .reaplicar)
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .active, estado: .suspenso), .nada)
        XCTAssertEqual(TerminalCenaLogic.acao(fase: .inactive, estado: .ativo), .nada)
    }
}
