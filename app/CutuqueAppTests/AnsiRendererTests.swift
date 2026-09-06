import XCTest
import SwiftUI
@testable import CutuqueApp

/// `Ansi.attributed` pinta a tela; `Ansi.plain` é para SAIR do app — o texto que
/// vai pra área de transferência e daí pro WhatsApp não pode levar `ESC[32m` no
/// meio.
final class AnsiRendererTests: XCTestCase {

    func testTextoSemAnsiPassaIgual() {
        XCTAssertEqual(Ansi.plain("cutuque: ok"), "cutuque: ok")
    }

    func testCorSgrDesaparece() {
        XCTAssertEqual(Ansi.plain("\u{1B}[32mverde\u{1B}[0m e normal"), "verde e normal")
    }

    func testCor256ETruecolorDesaparecem() {
        XCTAssertEqual(Ansi.plain("\u{1B}[38;5;208mlaranja\u{1B}[0m"), "laranja")
        XCTAssertEqual(Ansi.plain("\u{1B}[38;2;10;20;30mrgb\u{1B}[0m"), "rgb")
    }

    func testSequenciaNaoSgrDesaparece() {
        // Mover cursor e limpar tela não são conteúdo — `attributed` já as
        // descarta, e `plain` herda isso por construção.
        XCTAssertEqual(Ansi.plain("\u{1B}[2J\u{1B}[Hlimpo"), "limpo")
    }

    func testQuebraDeLinhaEEspacoSobrevivem() {
        // A tela de um terminal É espaço e quebra de linha; se `plain` comesse
        // isso, o texto colado no WhatsApp viraria uma linha só.
        XCTAssertEqual(Ansi.plain("a\nb  c\n"), "a\nb  c\n")
    }

    func testPlainEOMesmoTextoQueAttributedMostra() {
        // O par que importa: prova que `plain` não é um segundo varredor de ANSI
        // com regra própria — ele lê o MESMO resultado que a tela mostra. Sem
        // esta asserção, os testes acima passariam também para uma
        // implementação paralela que fosse divergindo em silêncio.
        let entrada = "\u{1B}[1;31merro\u{1B}[0m: \u{1B}[38;5;42mdetalhe\u{1B}[0m"
        let mostrado = String(Ansi.attributed(entrada, size: 12, defaultColor: .primary).characters)
        XCTAssertEqual(Ansi.plain(entrada), mostrado)
    }

    // MARK: attributedLines — a tela quebrada em linhas

    /// O varredor por linhas é o de verdade desde o conserto do travamento; se
    /// ele contar linha errado, a tela desenha deslocada.
    func testUmaLinhaPorQuebra() {
        let casos = ["", "sozinha", "a\nb", "a\nb\n", "\n", "a\n\nb"]
        for entrada in casos {
            let esperado = entrada.components(separatedBy: "\n").count
            let linhas = Ansi.attributedLines(entrada, size: 12, defaultColor: .primary)
            XCTAssertEqual(linhas.count, esperado, "contagem errada para \(entrada.debugDescription)")
        }
    }

    func testTextoDeCadaLinhaEODaEntrada() {
        let linhas = Ansi.attributedLines("\u{1B}[32mum\u{1B}[0m\ndois  \n", size: 12, defaultColor: .primary)
        XCTAssertEqual(linhas.map { String($0.characters) }, ["um", "dois  ", ""])
    }

    /// O motivo de o varredor por linhas existir em vez de um `split` seguido de
    /// uma varredura por pedaço: no TUI do claude a cor é aberta numa linha e
    /// vale nas seguintes. Varrer cada linha do zero pintaria de padrão tudo que
    /// herda cor — quase toda linha de bloco.
    func testCorAtravessaAQuebraDeLinha() {
        let vermelho = Color(.sRGB, red: 0.80, green: 0.24, blue: 0.24)
        let linhas = Ansi.attributedLines("\u{1B}[31mum\ndois\u{1B}[0m\ntres",
                                          size: 12, defaultColor: .primary)
        XCTAssertEqual(linhas.count, 3)
        XCTAssertEqual(linhas[0].runs.first?.foregroundColor, vermelho)
        XCTAssertEqual(linhas[1].runs.first?.foregroundColor, vermelho, "a cor tem que herdar da linha de cima")
        XCTAssertEqual(linhas[2].runs.first?.foregroundColor, Color.primary, "o reset da linha 2 tem que valer na 3")
    }

    func testNegritoTambemAtravessa() {
        let linhas = Ansi.attributedLines("\u{1B}[1mum\ndois", size: 12, defaultColor: .primary)
        XCTAssertEqual(linhas[0].runs.first?.font, Font.system(size: 12, design: .monospaced).bold())
        XCTAssertEqual(linhas[1].runs.first?.font, Font.system(size: 12, design: .monospaced).bold())
    }

    /// A barreira contra divergência, igual à que já existe entre `plain` e
    /// `attributed`: a tela desenhada linha a linha tem que ser o MESMO texto do
    /// bloco inteiro. Sem isto, os dois caminhos passam a mostrar coisas
    /// diferentes em silêncio.
    func testLinhasJuntasSaoOMesmoQueOBlocoInteiro() {
        let entrada = "\u{1B}[1;31merro\u{1B}[0m: \u{1B}[38;5;42mdetalhe\u{1B}[0m\nsegunda \u{1B}[34mlinha\nterceira\n"
        let porLinha = Ansi.attributedLines(entrada, size: 12, defaultColor: .primary)
            .map { String($0.characters) }
            .joined(separator: "\n")
        XCTAssertEqual(porLinha, Ansi.plain(entrada))
    }

    /// Linha em branco vem como `AttributedString` VAZIO — a view troca por um
    /// espaço porque `Text` vazio tem altura zero. Se um dia isto passar a vir
    /// com um espaço embutido, a troca da view viraria espaço dobrado.
    func testLinhaEmBrancoVemVazia() {
        let linhas = Ansi.attributedLines("a\n\nb", size: 12, defaultColor: .primary)
        XCTAssertTrue(linhas[1].characters.isEmpty)
    }

    /// Sequência ANSI grudada na quebra não pode comer a linha nem vazar cor
    /// para o lado errado.
    func testSgrColadoNaQuebra() {
        let linhas = Ansi.attributedLines("um\u{1B}[32m\nverde", size: 12, defaultColor: .primary)
        XCTAssertEqual(linhas.map { String($0.characters) }, ["um", "verde"])
        XCTAssertEqual(linhas[0].runs.first?.foregroundColor, Color.primary)
        XCTAssertEqual(linhas[1].runs.first?.foregroundColor,
                       Color(.sRGB, red: 0.30, green: 0.74, blue: 0.36))
    }
}
