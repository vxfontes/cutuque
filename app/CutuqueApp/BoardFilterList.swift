import SwiftUI

/// Coluna do meio quando o destino é o Board: os três eixos de filtro visíveis
/// ao mesmo tempo (no iPhone eles vivem espremidos numa barra horizontal) e a
/// busca, que aqui não cobre mais o kanban.
struct BoardFilterList: View {
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var nav: NavigationState
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    // "Estou estreito AGORA?" — mesmo eixo que `BoardView` lê; precisado aqui
    // pra calcular o MESMO predicado (ver `showsOwnFilterAndSearch` abaixo).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Este `BoardFilterList` só existe dentro de `RootSplitView`, que só é
    /// instanciado quando o idiom é `.pad` (`CutuqueApp.swift`) — por isso
    /// `isPad: true` é sempre verdade aqui, ao contrário do `BoardView` que
    /// também vive no `RootTabView` do iPhone.
    ///
    /// `showsOwnFilterAndSearch` responde "o `BoardView` é quem mostra a
    /// PRÓPRIA busca agora?" — e este `BoardFilterList` é o dono visível
    /// exatamente quando a resposta é `false` (mesma função pura testada em
    /// `BoardMoveLogicTests`, só negada): os dois ramos usam o MESMO
    /// predicado, então nunca os dois tratam `.focusSearch` ao mesmo tempo, e
    /// nunca os dois deixam de tratar (rodada 3 da revisão da Task 16).
    private var showsOwnFilterAndSearch: Bool {
        BoardLayout.showsOwnFilterAndSearch(isPad: true,
                                             horizontalSizeClassIsCompact: horizontalSizeClass == .compact,
                                             columnVisibilityIsDetailOnly: nav.columnVisibility == .detailOnly)
    }

    var body: some View {
        List {
            Section("Buscar") {
                TextField("Título, descrição, comentários…", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !model.searchResults.isEmpty {
                    ForEach(model.searchResults) { task in
                        Button { nav.boardSelection = task } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if task.archived == true {
                                    Text("ARQUIVADO").font(.caption2).fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                }
                                BoardCardRow(task: task)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Ambiente") { filterRows(selection: $model.filterGroup, options: model.groups) }
            Section("Tipo")     { filterRows(selection: $model.filterType,  options: model.types) }
            Section("Sessão")   { filterRows(selection: $model.filterSession, options: model.sessions) }

            if model.hasActiveFilter {
                Section {
                    Button(role: .destructive) {
                        model.filterGroup = "all"; model.filterType = "all"; model.filterSession = "all"
                    } label: {
                        Label("Limpar filtros", systemImage: "xmark.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("Board")
        .onChange(of: searchText) { _, q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { await model.search(q) }
            }
        }
        // Só consome o que trata — o board (coluna de detalhe) está vivo junto
        // e precisa receber o ⌘← / ⌘→. `.focusSearch` só é tratado aqui quando
        // ESTE `BoardFilterList` é quem está visível de fato ao lado do board
        // (`!showsOwnFilterAndSearch`) — do contrário quem foca é a busca
        // própria da `BoardView` (achado da rodada 3: os dois ramos precisam
        // ser mutuamente exclusivos por construção, nunca os dois tratando,
        // nunca os dois deixando passar).
        .onChange(of: nav.intent) { _, intent in
            switch intent {
            case .focusSearch:
                guard !showsOwnFilterAndSearch else { return }
                searchFocused = true
            default:
                return
            }
            nav.consume()
        }
    }

    @ViewBuilder
    private func filterRows(selection: Binding<String>, options: [String]) -> some View {
        Button { selection.wrappedValue = "all" } label: {
            HStack {
                Text("Todos")
                Spacer()
                if selection.wrappedValue == "all" { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .buttonStyle(.plain)
        ForEach(options, id: \.self) { option in
            Button { selection.wrappedValue = option } label: {
                HStack {
                    Text(option)
                    Spacer()
                    if selection.wrappedValue == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
