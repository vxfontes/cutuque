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

    func testRegraDos700Pt() {
        XCTAssertTrue(PadLayout.startsExpanded(detailWidth: 554))   // 11" em 3 colunas
        XCTAssertTrue(PadLayout.startsExpanded(detailWidth: 699))
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 700))  // limite é inclusivo pra cima
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 806))  // 13" em 3 colunas
    }

    func testLarguraZeroNaoDecideNada() {
        // Antes do primeiro layout a largura é 0; quem chama precisa ignorar,
        // mas a função não pode responder "expandido" por acidente.
        XCTAssertFalse(PadLayout.startsExpanded(detailWidth: 0))
    }
}
