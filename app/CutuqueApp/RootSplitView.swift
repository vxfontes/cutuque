import SwiftUI

/// Raiz do app no iPad: UMA `NavigationSplitView` de três colunas, construída
/// uma vez e nunca substituída.
///
/// Girar o aparelho não troca nada de estrutura — o próprio componente recolhe
/// a sidebar em retrato e a mostra em paisagem. É isso que preserva o espelho
/// do tmux vivo e a rolagem do chat na rotação (decisão #19). Trocar a raiz por
/// orientação faria o SwiftUI remontar a árvore, e o `onDisappear` do terminal
/// chama `stop()` e `restoreSize()` — girar derrubaria o pane no servidor.
struct RootSplitView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var nav: NavigationState

    /// Chave do que já teve a regra dos 700 pt aplicada, pra ela valer UMA vez
    /// por entrada em destino/painel e não brigar com o ⤡ da usuária.
    @State private var widthRuleAppliedFor: String?

    private var widthRuleKey: String { "\(nav.destination.rawValue)-\(nav.paneMode.rawValue)" }

    var body: some View {
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            DestinationSidebar()
        } content: {
            contentColumn
        } detail: {
            GeometryReader { geo in
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        guard width > 0, widthRuleAppliedFor != widthRuleKey else { return }
                        widthRuleAppliedFor = widthRuleKey
                        nav.applyWidthRule(detailWidth: width)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: widthRuleKey) { _, _ in widthRuleAppliedFor = nil }
        // Deep-link do push / Live Activity cai sempre em Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { nav.destination = .sessions }
        }
    }

    @ViewBuilder private var contentColumn: some View {
        switch nav.destination {
        case .sessions:
            SessionListView(splitSelection: $nav.selection)
        case .board:
            BoardFilterList()
        case .archive:
            ArchiveView(embedded: true, selection: $nav.archiveSelection)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch nav.destination {
        case .sessions:
            if let selection = nav.selection {
                // .id força a troca de sessão a destruir o painel anterior — é
                // aí, e só aí, que o `restoreSize()` do terminal deve rodar.
                SessionDetailPane(selection: selection).id(selection)
            } else {
                ContentUnavailableView("Escolha uma sessão", systemImage: "list.bullet.rectangle",
                                       description: Text("A conversa e o terminal aparecem aqui."))
            }
        case .board:
            BoardView()
        case .archive:
            if let task = nav.archiveSelection {
                ArchivedTaskPane(task: task)
            } else {
                ContentUnavailableView("Escolha um card", systemImage: "archivebox",
                                       description: Text("Os concluídos das semanas fechadas ficam aqui."))
            }
        }
    }
}

/// Sidebar. Sessões, Board e Arquivo são destinos de coluna; Histórico e
/// Ajustes continuam em sheet — são telas de consulta pontual, não valem uma
/// reescrita pra virar coluna.
///
/// O **status do hub** de propósito NÃO está aqui: a `HubStatusView` precisa
/// das sessões já carregadas (`sessions:`/`live:`) pro resumo, e a sidebar não
/// as tem. Ele fica onde sempre esteve, na toolbar da lista de sessões, com os
/// dados de verdade e o indicador colorido.
struct DestinationSidebar: View {
    @EnvironmentObject private var nav: NavigationState
    @State private var showingHistory = false
    @State private var showingSettings = false

    /// `List(selection:)` só existe para binding OPCIONAL; `nav.destination` é
    /// não-opcional de propósito (sempre há um destino escolhido — contrato da
    /// Task 5, coberto em `NavigationStateTests`). Aqui só embrulha/desembrulha
    /// pra casar com a API do List — a seleção nunca fica nil de verdade.
    private var destinationBinding: Binding<PadDestination?> {
        Binding(
            get: { nav.destination },
            set: { if let newValue = $0 { nav.destination = newValue } }
        )
    }

    var body: some View {
        List(selection: destinationBinding) {
            Section {
                ForEach(PadDestination.allCases) { destination in
                    Label(destination.label, systemImage: destination.symbol)
                        .tag(destination)
                }
            }
            Section {
                Button { showingHistory = true } label: {
                    Label("Histórico", systemImage: "clock.arrow.circlepath")
                }
                Button { showingSettings = true } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Cutuque")
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .sheet(isPresented: $showingSettings) { HubSettingsView() }
    }
}

/// Card arquivado no painel de detalhe (só leitura).
struct ArchivedTaskPane: View {
    let task: BoardTask
    @StateObject private var readOnlyModel = BoardModel()

    var body: some View {
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true)
    }
}

// MARK: - Stubs temporários (substituídos na Task 8)

struct SessionDetailPane: View {
    let selection: DetailSelection
    var body: some View { Text("painel da sessão") }
}
