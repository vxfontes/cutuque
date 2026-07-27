import XCTest
@testable import CutuqueApp

final class TerminalGeometryTests: XCTestCase {

    // Os números vêm da conta que já roda hoje na TerminalMirrorView:
    // cols = (largura - 16) / (fonte * 0.62)
    func testColunasNoIPhoneComFonteDeHoje() {
        // iPhone 15 Pro em retrato, 10 pt: (393-16)/6.2 = 60.8
        XCTAssertEqual(TerminalGeometry.columns(width: 393, fontPt: 10), 60)
    }

    func testColunasNoIPadExpandidoComFonteDoIPad() {
        // 11" expandido, 13 pt: (1194-16)/8.06 = 146.1
        XCTAssertEqual(TerminalGeometry.columns(width: 1194, fontPt: 13), 146)
    }

    func testColunasNoIPadEmTresColunas() {
        // detalhe de 726 pt, 13 pt: (726-16)/8.06 = 88.0
        XCTAssertEqual(TerminalGeometry.columns(width: 726, fontPt: 13), 88)
    }

    func testColunasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.columns(width: 100, fontPt: 13), 30)
    }

    func testLinhasDescontamAsBarras() {
        // (834-120)/(13*1.28) = 42.9
        XCTAssertEqual(TerminalGeometry.rows(height: 834, fontPt: 13), 42)
    }

    func testLinhasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.rows(height: 130, fontPt: 13), 20)
    }

    func testFontePadraoMudaPorIdiom() {
        XCTAssertEqual(TerminalGeometry.defaultFontPt(isPad: false), 10)
        XCTAssertEqual(TerminalGeometry.defaultFontPt(isPad: true), 13)
    }

    // `PadLayout.startsExpanded(detailWidth:)` (a antiga "regra dos 700 pt"
    // que decidia o colapso da split view pela largura medida) foi removida
    // na tarefa que trocou o critério pra orientação — ver
    // `NavigationState.applyLayoutRule` e `WidthRuleGateTests`.
    // `PadLayout.expandThreshold` continua existindo: `BoardLayout.isRegularWidth`
    // (`BoardMoveLogic.swift`) ainda o usa pra decidir a barra de filtros
    // própria do board, um cálculo diferente e não tocado por esta tarefa.

    // fontMin/fontMax vieram da Task 3 sem consumidor: a TerminalMirrorView
    // (Task 9) é quem passa a usar os dois nos limites do A−/A+.
    func testLimitesDeFontePraOsBotoesAMenosEAMais() {
        XCTAssertEqual(TerminalGeometry.fontMin, 5)
        XCTAssertEqual(TerminalGeometry.fontMax, 22)
    }
}
