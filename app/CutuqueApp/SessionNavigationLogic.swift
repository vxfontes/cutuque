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

    /// O dicionário "o que está vivo agora" que `OpenTabs.reconciliar(vivas:)`
    /// usa pra decidir quem fica, quem volta a viver e quem vira `.morta`.
    ///
    /// Extraída pura (12/08/2026 — achado crítico #2 da revisão adversarial):
    /// a `SessionListView` só montava este dicionário a partir de `live`
    /// (as entradas do poll de "ao vivo"), então nenhuma chave `.chat` jamais
    /// aparecia nele — e `OpenTabs.dependeDeAlgoVivo` marca `.chat` como
    /// "depende de algo vivo" (corretamente: uma aba de chat cuja sessão saiu
    /// do registry DEVE virar aviso). Resultado: toda aba de chat morria no
    /// primeiro reconciliar, ~15s depois de aberta, mesmo com a sessão viva.
    /// O bug era o dicionário incompleto, não o `dependeDeAlgoVivo`.
    ///
    /// `sessions` cobre o lado `.chat` (uma chave por `Session` do registry);
    /// `live` cobre o lado `.live`. Os dois tipos nunca colidem em
    /// `ChaveDeAba` (o campo `tipo` já os separa), então o único cuidado é
    /// colisão DENTRO de `live` (dois panes podem produzir a mesma chave) —
    /// mantém "o primeiro ganha" como o `Dictionary(_:uniquingKeysWith:)`
    /// original já fazia.
    static func vivasPorChave(live: [LiveEntry], sessions: [Session]) -> [ChaveDeAba: TabConteudo] {
        var vivas = Dictionary(
            live.map { (ChaveDeAba.para(.live($0)), TabConteudo.sessao(.live($0))) },
            uniquingKeysWith: { primeiro, _ in primeiro }
        )
        let chats = Dictionary(
            sessions.map { (ChaveDeAba.para(.session($0)), TabConteudo.sessao(.session($0))) },
            uniquingKeysWith: { primeiro, _ in primeiro }
        )
        vivas.merge(chats) { primeiro, _ in primeiro }
        return vivas
    }
}
