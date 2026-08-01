import SwiftUI

/// Mostra o conteúdo de um arquivo de texto da máquina. Binário ou acima do teto
/// de 1 MB não é renderizado: puxar bytes crus para a tela do iPhone não ajuda
/// ninguém, e o hub já manda esses casos marcados e sem conteúdo.
///
/// Nesta fase é só leitura — editar e salvar entram na F2.
struct FileViewerView: View {
    let machine: String
    let entry: FileEntry

    @State private var content: FileContent?
    @State private var error: String?
    private let api = APIClient()

    var body: some View {
        Group {
            if let content {
                if let motivo = content.unreadableReason {
                    ContentUnavailableView {
                        Label(content.binary ? "Arquivo binário" : "Arquivo grande demais",
                              systemImage: content.binary ? "doc.badge.gearshape" : "doc.badge.ellipsis")
                    } description: {
                        Text("\(motivo) (\(entry.sizeLabel))")
                    }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(content.content)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Não deu para abrir", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Tentar de novo") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Compartilhar cobre "salvar no app Arquivos" para texto. Binário
            // precisa de uma rota que sirva os bytes — entra na F2.
            if let content, content.isReadable {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: content.content, preview: SharePreview(entry.name)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            content = try await api.readFile(machine: machine, path: entry.path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
