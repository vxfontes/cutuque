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
}
