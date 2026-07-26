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
        // e precisa receber o ⌘← / ⌘→.
        .onChange(of: nav.intent) { _, intent in
            switch intent {
            case .focusSearch: searchFocused = true
            default:           return
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
