import XCTest
@testable import CutuqueApp

/// A aritmética de "quais linhas do buffer estão na tela". Sozinha ela é trivial
/// — e é exatamente por isso que o erro de 1 passa batido: com `base` errado
/// some a última linha da tela (a que a usuária mais quer copiar, onde está o
/// resultado do comando que ela acabou de rodar).
final class JanelaVisivelTests: XCTestCase {

    func testTelaNoTopoDoBuffer() {
        let j = JanelaVisivel.linhas(yDisp: 0, rows: 24)
        XCTAssertEqual(j?.topo, 0)
        XCTAssertEqual(j?.base, 23, "24 linhas visíveis são 0...23, não 0...24")
    }

    func testTelaRoladaSomaODeslocamento() {
        let j = JanelaVisivel.linhas(yDisp: 100, rows: 24)
        XCTAssertEqual(j?.topo, 100)
        XCTAssertEqual(j?.base, 123)
    }

    func testTelaDeUmaLinhaSoTemTopoIgualABase() {
        let j = JanelaVisivel.linhas(yDisp: 7, rows: 1)
        XCTAssertEqual(j?.topo, 7)
        XCTAssertEqual(j?.base, 7)
    }

    func testTerminalSemAlturaNaoTemJanela() {
        // Acontece de verdade: o emulador nasce com frame .zero antes do
        // primeiro layout. Devolver uma janela inválida aqui viraria um
        // getText com end antes do start.
        XCTAssertNil(JanelaVisivel.linhas(yDisp: 0, rows: 0))
        XCTAssertNil(JanelaVisivel.linhas(yDisp: 5, rows: -1))
    }
}
