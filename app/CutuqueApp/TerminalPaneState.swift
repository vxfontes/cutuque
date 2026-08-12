import Foundation

/// O estado de um painel de terminal. Três valores, não dois: o booleano `isActive`
/// que existia antes não distinguia trocar de aba de fechar o terminal, e a
/// diferença é a largura do pane no tmux do PC.
///
/// | estado      | polling | largura do tmux |
/// |-------------|---------|-----------------|
/// | `ativo`     | roda    | aplicada        |
/// | `suspenso`  | para    | **mantida**     |
/// | `liberado`  | para    | **devolvida**   |
///
/// `suspenso` é a aba de trás: o pane continua trabalhando na grade que já tem, e
/// voltar para a aba não precisa reenviar resize. `liberado` é o `✕`, a aba fechada,
/// a aba que dormiu por causa do teto de 6 (D3) e o app no background (D7).
enum TerminalPaneState: String, Codable, Equatable {
    case ativo
    case suspenso
    case liberado

    /// Só o painel visível espelha a tela — os de trás ficam montados e calados
    /// (decisão #19: nunca desmontar para trocar de painel).
    var fazPolling: Bool { self == .ativo }

    /// Devolver a largura é transição, não estado: só ao ENTRAR em `liberado`.
    /// Chamar duas vezes não faria mal ao tmux, mas faria um POST por medida de
    /// layout, e a medida muda em toda rotação.
    static func devolveLargura(de anterior: TerminalPaneState, para novo: TerminalPaneState) -> Bool {
        novo == .liberado && anterior != .liberado
    }
}

/// A chave do `.task(id:)` que dispara resize e polling no TerminalMirrorView.
/// O estado entra na chave DE PROPÓSITO: sem ele o `.task` não reentra quando só o
/// estado muda (era `"\(cols)x\(rows)"`), e era esse o motivo do `✕` do iPad não
/// devolver a largura.
enum TerminalResizeKey {
    static func chave(cols: Int?, rows: Int?, estado: TerminalPaneState) -> String {
        guard let cols, let rows else { return "sem-medida·\(estado.rawValue)" }
        return "\(cols)x\(rows)·\(estado.rawValue)"
    }
}
