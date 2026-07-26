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
}
