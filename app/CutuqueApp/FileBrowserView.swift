import SwiftUI

/// Painel Arquivos da aba Máquinas: navega pastas e arquivos de um host. Pasta
/// abre outro nível; arquivo abre o visualizador. Ocultos escondidos por padrão,
/// com toggle — igual ao seletor de pastas.
///
/// A navegação é por pilha: entrar numa pasta empurra outra `FileBrowserView` e
/// o voltar nativo faz o papel do "..". O `FolderPickerView` precisa do ".."
/// porque é um sheet sem pilha; aqui não.
struct FileBrowserView: View {
    let machine: String
    /// Caminho a listar. Vazio = home da máquina.
    let path: String

    @State private var listing: FileListing?
    @State private var loading = false
    @State private var error: String?
    // Preferência pega em toda a navegação: destravar os ocultos uma vez vale
    // para as pastas seguintes.
    @AppStorage("machines.showHiddenFiles") private var showHidden = false
    private let api = APIClient()

    private var visible: [FileEntry] {
        listing?.visibleEntries(showHidden: showHidden) ?? []
    }

    var body: some View {
        List {
            ForEach(visible) { entry in
                if entry.isDir {
                    NavigationLink {
                        FileBrowserView(machine: machine, path: entry.path)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                            .lineLimit(1)
                            .foregroundStyle(entry.isHidden ? Color.secondary : Color.primary)
                    }
                } else {
                    NavigationLink {
                        FileViewerView(machine: machine, entry: entry)
                    } label: {
                        HStack(spacing: 8) {
                            Label(entry.name, systemImage: "doc")
                                .lineLimit(1)
                                .foregroundStyle(entry.isHidden ? Color.secondary : Color.primary)
                            Spacer(minLength: 8)
                            Text(entry.sizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if visible.isEmpty && !loading {
                Text(showHidden ? "Pasta vazia" : "Nada visível aqui — talvez só itens ocultos.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(titulo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showHidden) {
                    Label("Ocultos", systemImage: showHidden ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
            }
        }
        .overlay { if loading && listing == nil { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .alert("Não deu para listar", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Nome da pasta atual; na raiz da navegação, o nome da máquina.
    private var titulo: String {
        guard let p = listing?.path, p != "/" else { return machine }
        return (p as NSString).lastPathComponent
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            listing = try await api.listFiles(machine: machine, path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
