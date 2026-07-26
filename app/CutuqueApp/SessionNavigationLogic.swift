/// O que fazer para levar a `SessionListView` até uma sessão (ou entrada ao
/// vivo), sem I/O nem SwiftUI — testável sem hosting.
enum SessionNavigationTarget: Equatable {
    /// iPad (`splitSelection` não-nil): publica a escolha; o detalhe reage sozinho.
    case selection(DetailSelection)
    /// iPhone: sessão do tmux — abre o TERMINAL AO VIVO em sheet, não o detalhe
    /// (que fica vazio para sessões externas — bug antigo).
    case liveSheet(LiveEntry)
    /// iPhone: sessão comum — empurra na `NavigationStack`.
    case push(Session)
}

/// Decisão pura por trás de `resolveDeepLink()` e `go(to:)` da `SessionListView`
/// (Task 6). `nil` = nada a fazer (já está exatamente onde precisa).
enum SessionNavigationLogic {

    /// Deep-link vindo de uma notificação (ou reprocessado ao mudar a lista):
    /// decide splitSelection vs. tmuxTarget (sheet ao vivo) vs. path.
    /// `tmuxEntry` é a entrada ao vivo já montada pelo chamador quando a sessão
    /// tem `tmuxTarget` (nil quando não tem). `pathTopID` é o topo atual da
    /// pilha do iPhone (nil se vazia) — só para não empurrar a mesma sessão 2x.
    static func deepLink(
        session: Session, tmuxEntry: LiveEntry?, embedded: Bool, pathTopID: String?
    ) -> SessionNavigationTarget? {
        if embedded {
            return .selection(tmuxEntry.map { .live($0) } ?? .session(session))
        } else if let tmuxEntry {
            return .liveSheet(tmuxEntry)
        } else if pathTopID != session.id {
            return .push(session)
        }
        return nil
    }

    /// Criar/adotar uma sessão (`go(to:)`): sempre abre o detalhe normal —
    /// diferente de `deepLink`, não olha `tmuxTarget` (a sessão acabou de
    /// nascer/ser adotada pelo app).
    static func goTo(session: Session, embedded: Bool, pathTopID: String?) -> SessionNavigationTarget? {
        if embedded {
            return .selection(.session(session))
        } else if pathTopID != session.id {
            return .push(session)
        }
        return nil
    }
}
