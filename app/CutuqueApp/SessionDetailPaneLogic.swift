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

    /// Em que painel o detalhe ABRE, dado o que esta seleção tem. `nil` quando
    /// `current` já serve — não há nada a mudar.
    ///
    /// Duas responsabilidades, e a segunda é nova: além de corrigir um
    /// `paneMode` impossível (seleção sem chat não pode mostrar chat), ela
    /// impõe o padrão de entrada das sessões AO VIVO. `paneMode` é estado
    /// compartilhado em `NavigationState`, então sem isso a sessão ao vivo
    /// herdaria o painel da anterior.
    ///
    /// - **Tem info** (entrada ao vivo do tmux): abre SEMPRE em `.info`, a
    ///   pedido da usuária ("antes de abrir assim mostra as infos e tudo
    ///   mais") — é a paridade com o iPhone, onde tocar numa linha ao vivo
    ///   abre `LiveDetailView` e o terminal vem de um botão. Vale a cada
    ///   seleção, não só na primeira: o pane é remontado por sessão
    ///   (`.id(selection)` em `RootSplitView`), então escolher outra sessão ao
    ///   vivo volta pras informações dela.
    /// - **Sem chat e sem info**: só sobra terminal.
    /// - **Com chat**: mantém o que o usuário já escolhia entre chat e
    ///   terminal; `.info` (herdado de uma seleção ao vivo anterior) não
    ///   existe aqui e vira `.chat`, assim como `.terminal` numa sessão fora
    ///   do tmux.
    static func entryPaneMode(hasChat: Bool, hasTerminal: Bool, hasInfo: Bool,
                              current: PaneMode) -> PaneMode? {
        let required: PaneMode
        if hasInfo {
            required = .info
        } else if !hasChat {
            required = .terminal
        } else if !hasTerminal || current == .info {
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

    /// Resolve QUAL título de chat entra em `paneTitle`: o ao vivo (subido
    /// via `LiveChatTitleKey`, que acompanha `session_updated`/`snapshot`)
    /// quando presente, senão o fallback estático calculado a partir do
    /// snapshot congelado de `nav.selection`.
    ///
    /// Existe porque `SessionDetailPane.session` vem de `nav.selection` —
    /// congelado de propósito (só reatribuído no toque numa linha ou
    /// deep-link, pra não remontar o pane a cada campo que muda) — enquanto
    /// `SessionDetailViewModel.session` é atualizado ao vivo e o hub PODE
    /// mudar `Session.title` depois da criação (`Registry.Reclaim`). Sem
    /// preferir o ao vivo aqui, o título do chat no iPad ficaria preso no
    /// valor de quando a sessão foi selecionada — regressão em relação ao
    /// iPhone, que sempre leu o título ao vivo direto.
    static func resolvedChatTitle(live: String?, fallback: String?) -> String? {
        live ?? fallback
    }
}
