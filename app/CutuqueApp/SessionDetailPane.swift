import SwiftUI

/// Painel de detalhe de uma sessão no iPad: chat e terminal empilhados, com um
/// seletor no topo.
///
/// Os dois ficam na hierarquia o tempo todo, alternando por opacidade — trocar
/// de aba não remonta nada, então a rolagem do chat e o espelho do tmux
/// sobrevivem à troca. O terminal para de fazer poll por `isActive`, não por
/// desmontagem.
struct SessionDetailPane: View {
    let selection: DetailSelection
    @EnvironmentObject private var nav: NavigationState
    @ObservedObject private var namer = SessionNamesStore.shared
    /// Título ao vivo do chat, subido pelo `SessionDetailView` via
    /// `LiveChatTitleKey` (acompanha `session_updated`/`snapshot`,
    /// desacoplado do snapshot congelado de `nav.selection` — ver o
    /// comentário na chave e em `SessionDetailPaneLogic.resolvedChatTitle`).
    /// `nil` até a primeira preference chegar (mostra o fallback estático
    /// enquanto isso).
    @State private var liveChatTitle: String?

    private var session: Session? {
        if case .session(let s) = selection { return s }
        return nil
    }

    /// Alvo tmux desta seleção: uma entrada ao vivo sempre tem; uma sessão do
    /// registry só se ela roda dentro do tmux. Decisão pura (testável sem
    /// hosting de View) em `SessionDetailPaneLogic.terminalTarget`.
    private var terminal: (machine: String, target: String, title: String)? {
        SessionDetailPaneLogic.terminalTarget(for: selection) { namer.displayTitle(for: $0) }
    }

    private var showsChat: Bool { nav.paneMode == .chat }

    /// Título do chat pra entrar em `paneTitle`: prefere o ao vivo
    /// (`liveChatTitle`, subido via `LiveChatTitleKey`) e só cai pro estático
    /// (apelido sobre o snapshot congelado de `session`) antes da primeira
    /// preference chegar. Decisão pura em
    /// `SessionDetailPaneLogic.resolvedChatTitle`.
    private var chatTitle: String? {
        SessionDetailPaneLogic.resolvedChatTitle(
            live: liveChatTitle,
            fallback: session.map { namer.displayTitle(for: $0) }
        )
    }

    /// Único título de navegação do pane — `SessionDetailView`/
    /// `TerminalMirrorView` embutidas aqui recebem `ownsNavigationTitle:
    /// false` e não contribuem mais nada ao `.navigationTitle` (nem uma
    /// string vazia). Decisão pura em `SessionDetailPaneLogic.paneTitle`.
    private var paneTitle: String {
        SessionDetailPaneLogic.paneTitle(
            showsChat: showsChat,
            chatTitle: chatTitle,
            terminalTitle: terminal?.title
        )
    }

    var body: some View {
        ZStack {
            if let session {
                SessionDetailView(session: session, isActive: showsChat, ownsNavigationTitle: false)
                    .opacity(showsChat ? 1 : 0)
                    .allowsHitTesting(showsChat)
                    .accessibilityHidden(!showsChat)
            }
            if let terminal {
                TerminalMirrorView(machine: terminal.machine, target: terminal.target,
                                   title: terminal.title, isActive: !showsChat,
                                   ownsNavigationTitle: false)
                    .opacity(showsChat ? 0 : 1)
                    .allowsHitTesting(!showsChat)
                    .accessibilityHidden(showsChat)
            }
        }
        .navigationTitle(paneTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Único leitor de `LiveChatTitleKey` — só o `SessionDetailView`
        // escreve nela, sem concorrência a resolver.
        .onPreferenceChange(LiveChatTitleKey.self) { liveChatTitle = $0 }
        .toolbar {
            if session != nil, terminal != nil {
                ToolbarItem(placement: .principal) { paneSelector }
            }
            ToolbarItem(placement: .topBarTrailing) { expandButton }
        }
        .onAppear {
            // Seleção sem chat só pode mostrar terminal, e vice-versa. Decisão
            // pura (testável sem hosting de View) em
            // `SessionDetailPaneLogic.correctedPaneMode`.
            if let corrected = SessionDetailPaneLogic.correctedPaneMode(
                hasChat: session != nil, hasTerminal: terminal != nil, current: nav.paneMode
            ) {
                nav.paneMode = corrected
            }
        }
    }

    private var paneSelector: some View {
        Picker("Painel", selection: $nav.paneMode) {
            Text("Chat").tag(PaneMode.chat)
            Text("Terminal").tag(PaneMode.terminal)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
    }

    private var expandButton: some View {
        let expanded = nav.columnVisibility == .detailOnly
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { nav.toggleColumns() }
        } label: {
            Image(systemName: expanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        .accessibilityLabel(expanded ? "Recolher para três colunas" : "Expandir o painel")
    }
}
