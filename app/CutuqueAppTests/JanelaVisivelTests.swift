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

/// A ponte sem `TerminalView` — o estado em que ela NASCE.
///
/// Mora neste arquivo porque testa a outra metade de `PTYTerminalView.swift`: a
/// leitura da tela. Só o caso "ainda não tem view" cabe em XCTest — o resto de
/// `TerminalTexto` exige um `TerminalView` de verdade, com layout feito e buffer
/// preenchido, e isso é verificação no aparelho, não teste de unidade.
///
/// Vale testar porque este é o instante perigoso do menu de copiar: entre abrir a
/// máquina e o primeiro layout do emulador a ponte está vazia, e é aí que "Copiar
/// tela" sobrescreveria a área de transferência com string vazia se ninguém
/// segurasse (achado `importante` da revisão da Task 5, 12/08/2026).
@MainActor
final class TerminalTextoSemViewTests: XCTestCase {

    func testPonteSemViewNaoTemTela() {
        XCTAssertEqual(TerminalTexto().telaVisivel(), "")
    }

    func testPonteSemViewNaoTemSelecao() {
        // `nil` e não `""`: quem decide entre seleção e tela distingue os dois —
        // "não selecionou" tem de cair na tela, não virar cópia vazia.
        XCTAssertNil(TerminalTexto().selecionado())
    }

    func testTerminalRecemAbertoNaoProduzTextoParaCopiar() {
        // A composição que o menu do ssh usa de verdade. Vazio aqui é o que
        // desabilita o item e o que faz o `guard` da ação desistir.
        let ponte = TerminalTexto()
        let texto = TextoParaCopiar.doTerminal(selecionado: ponte.selecionado(),
                                               tela: ponte.telaVisivel())
        XCTAssertTrue(texto.isEmpty)
    }
}
