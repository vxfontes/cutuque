import SwiftUI
import XCTest
@testable import CutuqueApp

final class TerminalKeyboardTests: XCTestCase {

    func testLetraComumFicaNaLinhaLocal() {
        // O espelho é polling: mandar letra por letra custaria ~250 ms cada.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "a", modifiers: []))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "Z", modifiers: [.shift]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: " ", modifiers: []))
    }

    func testTeclasDeTerminalVaoDiretoProTmux() {
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.escape.character, modifiers: []), "Escape")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.tab.character, modifiers: []), "Tab")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.upArrow.character, modifiers: []), "Up")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.downArrow.character, modifiers: []), "Down")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.leftArrow.character, modifiers: []), "Left")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.rightArrow.character, modifiers: []), "Right")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.pageUp.character, modifiers: []), "PageUp")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: KeyEquivalent.pageDown.character, modifiers: []), "PageDown")
    }

    func testControleCEDVaoProTmux() {
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: "c", modifiers: [.control]), "C-c")
        XCTAssertEqual(TerminalKeyboard.tmuxKey(for: "d", modifiers: [.control]), "C-d")
    }

    func testOptionComSetaMoveOCursorNaLinha() {
        // ⌥← e ⌥→ são pra andar dentro do texto que está sendo composto.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.leftArrow.character, modifiers: [.option]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.rightArrow.character, modifiers: [.option]))
    }

    func testEnterNaoEhEncaminhado() {
        // ⏎ envia a linha inteira via send(), não uma tecla solta.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.return.character, modifiers: []))
    }

    func testComandoNuncaEhEncaminhado() {
        // ⌘. ⌘R ⌘T etc. são atalhos do app, não teclas do terminal.
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: "c", modifiers: [.command]))
        XCTAssertNil(TerminalKeyboard.tmuxKey(for: KeyEquivalent.escape.character, modifiers: [.command]))
    }

    // MARK: Letras de comando da gaveta

    func testLetrasDeComandoNaOrdemDaLegenda() {
        // A ordem é a da legenda que a própria TUI desenha (j/k rolar, x parar,
        // r reiniciar, p pausar, s salvar): a barra tem que ler igual ao que está
        // na tela, senão achar o botão vira caça ao tesouro.
        XCTAssertEqual(TerminalKeyboard.letrasDeComando, ["j", "k", "x", "r", "p", "s"])
    }

    func testLetraDaGavetaContinuaIndoProALinhaQuandoDigitada() {
        // A gaveta manda a letra como TECLA (sendKey). Digitar a mesma letra no
        // teclado tem que seguir caindo na linha local — senão escrever "prompt"
        // viraria uma saraivada de comandos de TUI.
        for letra in TerminalKeyboard.letrasDeComando {
            XCTAssertNil(
                TerminalKeyboard.tmuxKey(for: Character(letra), modifiers: []),
                "\(letra) digitada deveria ficar na linha local"
            )
        }
    }

    func testLetrasDeComandoSaoTeclaSimples() {
        // Contrato com a allowlist do hub (tmuxAllowedKeys): valor literal, uma
        // letra ASCII. Lá a tecla é concatenada CRUA no shell do ssh — nada aqui
        // pode virar espaço, aspa ou nome composto.
        for letra in TerminalKeyboard.letrasDeComando {
            XCTAssertEqual(letra.count, 1, "\(letra) não é uma tecla simples")
            XCTAssertTrue(
                letra.allSatisfy { $0.isASCII && $0.isLetter },
                "\(letra) tem caractere que não é letra ASCII"
            )
        }
        XCTAssertEqual(Set(TerminalKeyboard.letrasDeComando).count,
                       TerminalKeyboard.letrasDeComando.count,
                       "letra repetida na gaveta")
    }
}
