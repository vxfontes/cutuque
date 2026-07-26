import SwiftUI

/// Divisão do teclado físico no espelho de terminal, numa regra só.
///
/// O espelho não é um PTY: é polling de 1,5 s, e `sendKey` custa round-trip
/// mais 250 ms de espera. Digitar caractere-a-caractere está descartado por
/// construção — então caractere imprimível vai pra linha de input local
/// (instantâneo, zero rede) e só tecla com semântica de terminal é encaminhada.
enum TerminalKeyboard {

    /// Nome da tecla no tmux, ou nil se o caractere deve ser digitado na linha.
    static func tmuxKey(for character: Character, modifiers: EventModifiers) -> String? {
        // ⌘ é território dos atalhos do app.
        if modifiers.contains(.command) { return nil }

        if modifiers.contains(.control) {
            switch character {
            case "c": return "C-c"
            case "d": return "C-d"
            default:  break
            }
        }

        // ⌥← / ⌥→ andam dentro do texto sendo composto.
        if modifiers.contains(.option) { return nil }

        switch character {
        case KeyEquivalent.escape.character:    return "Escape"
        case KeyEquivalent.tab.character:       return "Tab"
        case KeyEquivalent.upArrow.character:   return "Up"
        case KeyEquivalent.downArrow.character: return "Down"
        case KeyEquivalent.leftArrow.character: return "Left"
        case KeyEquivalent.rightArrow.character: return "Right"
        case KeyEquivalent.pageUp.character:    return "PageUp"
        case KeyEquivalent.pageDown.character:  return "PageDown"
        default:                                return nil
        }
    }
}
