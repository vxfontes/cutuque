import SwiftUI

/// Navegador de pastas do Mac: entra em subpastas (tap), sobe de nível (".."), e
/// "Usar esta" devolve o caminho atual. Pastas ocultas (`.algo`) ficam escondidas
/// por padrão, com um toggle para mostrar (para alcançar `.maestri` etc.).
/// Alimenta a escolha do cwd ao criar uma sessão nova.
struct FolderPickerView: View {
    let machine: String
    /// Chamado com o caminho escolhido ("" = home da máquina).
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirListing?
    @State private var loading = false
    @State private var error: String?
    @State private var showHidden = false
    private let api = APIClient()

    private var visibleDirs: [DirEntry] {
        let all = listing?.dirs ?? []
        return showHidden ? all : all.filter { !$0.isHidden }
    }

    var body: some View {
        NavigationStack {
            List {
                if let listing {
                    Section {
                        // Subir um nível (some na raiz "/").
                        if listing.path != "/" {
                            Button {
                                load(listing.parent)
                            } label: {
                                Label("..", systemImage: "arrow.up.left.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if visibleDirs.isEmpty {
                            Text("Sem subpastas aqui")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleDirs) { dir in
                            Button {
                                load(dir.path)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(dir.isHidden ? Color.secondary : Color.blue)
                                    Text(dir.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(listing.path)
                            .font(.footnote)
                            .textCase(nil)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .overlay {
                if loading && listing == nil {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView("Não consegui listar", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            }
            .navigationTitle("Escolher pasta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Usar esta") {
                        onSelect(listing?.path ?? "")
                        dismiss()
                    }
                    .disabled(listing == nil)
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle(isOn: $showHidden) {
                        Label("Mostrar ocultas", systemImage: "eye")
                    }
                    .font(.footnote)
                }
            }
            .task { if listing == nil { load("") } } // "" = home da máquina
        }
    }

    private func load(_ path: String) {
        loading = true
        error = nil
        Task {
            do {
                listing = try await api.listDirs(machine: machine, path: path)
            } catch {
                self.error = "O Mac não respondeu. Tente de novo."
            }
            loading = false
        }
    }
}
