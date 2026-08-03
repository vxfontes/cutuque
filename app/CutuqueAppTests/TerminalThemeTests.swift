import XCTest
@testable import CutuqueApp

/// Catálogo de paletas do terminal PTY: o `byID` não pode deixar o terminal
/// sem cor (tema removido/desconhecido), a conversão hex é a base de tudo
/// que a SwiftTerm recebe, e o catálogo tem que estar íntegro (16 ANSI, id
/// único) — um catálogo quebrado quebra `installColors` em silêncio, sem
/// erro nenhum pra apontar a causa.
final class TerminalThemeTests: XCTestCase {

    // MARK: - byID cai no Padrão

    func testIDVazioCaiNoPadrao() {
        XCTAssertEqual(TerminalPalette.byID("").id, TerminalPalette.padrao.id)
    }

    /// Tema removido de um catálogo futuro não pode deixar o terminal sem
    /// cor — a máquina continua guardando a string antiga, só o app não
    /// reconhece mais.
    func testIDDesconhecidoCaiNoPadrao() {
        XCTAssertEqual(TerminalPalette.byID("nao-existe-mais").id, TerminalPalette.padrao.id)
        XCTAssertEqual(TerminalPalette.byID("Dracula").id, TerminalPalette.padrao.id, "id é case-sensitive: 'Dracula' != 'dracula'")
    }

    func testIDConhecidoAchaOTema() {
        XCTAssertEqual(TerminalPalette.byID("dracula").name, "Dracula")
    }

    // MARK: - Conversão hex → componentes 0-255

    func testHexPretoViraZeroZeroZero() {
        let c = TerminalPalette.components8(hex: "#000000")
        XCTAssertEqual(c?.r, 0)
        XCTAssertEqual(c?.g, 0)
        XCTAssertEqual(c?.b, 0)
    }

    func testHexBrancoViraDuzentosECinquentaECinco() {
        let c = TerminalPalette.components8(hex: "#ffffff")
        XCTAssertEqual(c?.r, 255)
        XCTAssertEqual(c?.g, 255)
        XCTAssertEqual(c?.b, 255)
    }

    /// Valor arbitrário, maiúsculo e sem "#" — as duas formas que o catálogo
    /// usa (com "#") e uma variação plausível de entrada precisam bater.
    func testHexArbitrarioConvertePorCanal() {
        let c = TerminalPalette.components8(hex: "#FF8800")
        XCTAssertEqual(c?.r, 255)
        XCTAssertEqual(c?.g, 136)
        XCTAssertEqual(c?.b, 0)

        let semHash = TerminalPalette.components8(hex: "ff8800")
        XCTAssertEqual(semHash?.r, 255)
        XCTAssertEqual(semHash?.g, 136)
        XCTAssertEqual(semHash?.b, 0)
    }

    func testHexMalformadoNaoConverte() {
        XCTAssertNil(TerminalPalette.components8(hex: "not-a-color"))
        XCTAssertNil(TerminalPalette.components8(hex: "#fff"))
        XCTAssertNil(TerminalPalette.components8(hex: ""))
    }

    /// A expansão 8→16 bit (`valor * 257`) é o que `installColors` recebe de
    /// verdade — testa a ponta que a SwiftTerm consome, não só o hex cru.
    func testComponenteExpandeDe8Para16BitsSemPerdaNasPontas() {
        let branco = TerminalPalette.padrao.ansiSwiftTermColors
        // último ANSI do Padrão é "#E9EBEB" — checa que o canal 0xE9 (233)
        // virou 233*257 = 59881, não um valor truncado ou escalado errado.
        XCTAssertEqual(branco[15].red, 59881)
    }

    // MARK: - Integridade do catálogo

    func testTodoTemaTemDezesseisCoresAnsi() {
        for tema in TerminalPalette.all {
            XCTAssertEqual(tema.ansi.count, 16, "\(tema.name) tem \(tema.ansi.count) cores ANSI, precisa de 16")
        }
    }

    func testTodoIDEhUnico() {
        let ids = TerminalPalette.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "id repetido no catálogo: \(ids)")
    }

    func testPadraoEhOPrimeiroDoCatalogoComIDVazio() {
        XCTAssertEqual(TerminalPalette.all.first?.id, "")
    }

    /// Todo hex do catálogo (bg/fg/cursor/16 ANSI) precisa converter — um
    /// tema com hex quebrado passaria despercebido até abrir o terminal
    /// naquela máquina.
    func testTodoHexDoCatalogoConverte() {
        for tema in TerminalPalette.all {
            for hex in [tema.background, tema.foreground, tema.cursor] + tema.ansi {
                XCTAssertNotNil(TerminalPalette.components8(hex: hex), "\(tema.name): hex inválido \(hex)")
            }
        }
    }
}
