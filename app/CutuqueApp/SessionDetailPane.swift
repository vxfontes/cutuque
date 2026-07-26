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

    private var session: Session? {
        if case .session(let s) = selection { return s }
        return nil
    }

    /// Alvo tmux desta seleção: uma entrada ao vivo sempre tem; uma sessão do
    /// registry só se ela roda dentro do tmux.
    private var terminal: (machine: String, target: String, title: String)? {
        switch selection {
        case .live(let entry):
            return (entry.machine, entry.session.id, entry.session.title)
        case .session(let s):
            guard let target = s.tmuxTarget else { return nil }
            return (s.machine, target, namer.displayTitle(for: s))
        }
    }

    private var showsChat: Bool { nav.paneMode == .chat }

    var body: some View {
        ZStack {
            if let session {
                SessionDetailView(session: session)
                    .opacity(showsChat ? 1 : 0)
                    .allowsHitTesting(showsChat)
                    .accessibilityHidden(!showsChat)
            }
            if let terminal {
                TerminalMirrorView(machine: terminal.machine, target: terminal.target,
                                   title: terminal.title, isActive: !showsChat)
                    .opacity(showsChat ? 0 : 1)
                    .allowsHitTesting(!showsChat)
                    .accessibilityHidden(showsChat)
            }
        }
        .toolbar {
            if session != nil, terminal != nil {
                ToolbarItem(placement: .principal) { paneSelector }
            }
            ToolbarItem(placement: .topBarTrailing) { expandButton }
        }
        .onAppear {
            // Seleção sem chat só pode mostrar terminal, e vice-versa.
            if session == nil { nav.paneMode = .terminal }
            else if terminal == nil { nav.paneMode = .chat }
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
