import SwiftUI

/// Navegador de pastas do Mac: entra em subpastas (tap), sobe de nível (".."), e
/// "Usar esta" devolve o caminho atual. Pastas ocultas (`.algo`) ficam escondidas
/// por padrão, com um toggle para mostrar (para alcançar `.maestri` etc.).
/// Alimenta a escolha do cwd ao criar uma sessão nova e a pasta do painel Diff.
struct FolderPickerView: View {
    let machine: String
    /// Onde a navegação começa. Vazio = home da máquina.
    ///
    /// [20/09/2026] Existe porque o painel Diff reabre o seletor para trocar de
    /// repositório: começar no HOME toda vez obrigaria a refazer a descida
    /// inteira só para ir na pasta vizinha. Ao criar sessão continua vazio, que
    /// é o comportamento de sempre.
    var startPath: String = ""
    /// Chamado com o caminho escolhido ("" = home da máquina).
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// [13/08/2026] O ícone de pasta era `.blue` cravado — um dos "alguns
    /// lugares fica com cor padrao" do relato. Aqui o azul nunca significou
    /// nada (não é erro nem sucesso): é afeto de "isto é tocável", papel de
    /// destaque. Ver `EnvironmentValues.corDeDestaque` em `AppTheme.swift`.
    @Environment(\.corDeDestaque) private var corDeDestaque
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
                                        .foregroundStyle(dir.isHidden ? Color.secondary : corDeDestaque)
                                    Text(dir.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if dir.ehRepositorio {
                                        Image(systemName: "arrow.triangle.branch")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Repositório Git")
                                    }
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
                        HStack(spacing: 6) {
                            Text(listing.path)
                                .lineLimit(1)
                                .truncationMode(.head)
                            // A marca da pasta ATUAL importa porque é ela que o
                            // "Usar esta" devolve: sem isto, para saber se a
                            // pasta em que já se entrou é repositório seria
                            // preciso subir um nível só para ver o marcador.
                            if listing.ehRepositorio {
                                Image(systemName: "arrow.triangle.branch")
                                Text("repositório Git")
                            }
                        }
                        .font(.footnote)
                        .textCase(nil)
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
            .task { if listing == nil { load(startPath) } } // "" = home da máquina
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
