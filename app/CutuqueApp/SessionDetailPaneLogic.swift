import Foundation

/// Decisões puras do painel de detalhe da sessão (`SessionDetailPane`),
/// extraídas para caber em XCTest sem hosting de View — mesmo formato de
/// `BoardMoveLogic`: nada de SwiftUI, nada de rede, só os dois `if/else`
/// reais que a view tinha embutidos.
enum SessionDetailPaneLogic {

    /// Alvo tmux de uma seleção: uma entrada ao vivo sempre tem; uma sessão
    /// do registry só se ela roda dentro do tmux. `displayTitle` resolve o
    /// nome (apelido local, se houver) sem esta função depender do
    /// `SessionNamesStore` — só recebe a `Session` e devolve a string pronta.
    static func terminalTarget(
        for selection: DetailSelection,
        displayTitle: (Session) -> String
    ) -> (machine: String, target: String, title: String)? {
        switch selection {
        case .live(let entry):
            return (entry.machine, entry.session.id, entry.session.title)
        case .session(let s):
            guard let target = s.tmuxTarget else { return nil }
            return (s.machine, target, displayTitle(s))
        }
    }

    /// Corrige o `paneMode` quando a seleção só permite um dos dois painéis
    /// (seleção sem chat só pode mostrar terminal, e vice-versa). `nil`
    /// quando `current` já é válido — não há nada a mudar.
    static func correctedPaneMode(hasChat: Bool, hasTerminal: Bool, current: PaneMode) -> PaneMode? {
        let required: PaneMode
        if !hasChat {
            required = .terminal
        } else if !hasTerminal {
            required = .chat
        } else {
            return nil
        }
        return required == current ? nil : required
    }

    /// Único título de navegação do pane, computado a partir de `showsChat` —
    /// a fonte de verdade que substitui os dois `.navigationTitle` que
    /// disputavam a mesma barra quando `SessionDetailView` e
    /// `TerminalMirrorView` ficavam montadas juntas (ver
    /// `OwnedNavigationTitle.swift`). Correto por construção: não depende de
    /// quem "vence" a composição de preference keys concorrentes.
    ///
    /// `chatTitle`/`terminalTitle` já vêm resolvidos (apelido local incluso)
    /// — esta função só decide QUAL dos dois mostrar. Quando o lado
    /// preferido por `showsChat` não existe (seleção só tem um dos dois
    /// painéis — ver `correctedPaneMode`), cai pro que houver; `""` só no
    /// caso, teoricamente inatingível em uso normal, de nenhum dos dois
    /// existir.
    static func paneTitle(showsChat: Bool, chatTitle: String?, terminalTitle: String?) -> String {
        if showsChat, let chatTitle { return chatTitle }
        if !showsChat, let terminalTitle { return terminalTitle }
        return chatTitle ?? terminalTitle ?? ""
    }
}
