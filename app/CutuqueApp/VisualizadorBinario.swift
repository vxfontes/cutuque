import SwiftUI

/// O lado "não é texto" do visualizador de arquivos: imagem, vídeo, áudio, PDF,
/// zip — e também o texto que o hub não mandou inteiro.
///
/// Nasceu de dentro do `FileViewerView` (12/08/2026) sem mudar comportamento: a
/// separação existe para que a frente do preview e a frente do texto pudessem
/// ser escritas em paralelo sem disputar o mesmo arquivo.
///
/// `abaAtiva` é o que impede o vídeo de continuar tocando atrás de outra aba.
/// Não use `.onDisappear` para isso: com abas globais uma aba criada fica
/// montada para sempre e o `.onDisappear` **nunca dispara** lá dentro
/// (decisão #19) — é a mesma armadilha que produziu o "painel branco" e o
/// "Sessão encerrada" na leva das abas.
struct VisualizadorBinario: View {
    let machine: String
    let entry: FileEntry
    /// O que o hub disse sobre o arquivo. É daqui que sai o motivo de não ser
    /// texto — binário ou grande demais mudam o que a tela deve explicar.
    let content: FileContent
    let abaAtiva: Bool
    /// Erro de download sobe para a casca virar alerta: a tela continua útil e
    /// não pode ser substituída pelo aviso.
    let reportaErro: (String) -> Void

    /// Arquivo baixado para o tmp, pronto para o ShareLink.
    @State private var downloaded: URL?
    @State private var downloading = false
    private let api = APIClient()

    var body: some View {
        ContentUnavailableView {
            Label(content.binary ? "Arquivo binário" : "Arquivo grande demais",
                  systemImage: content.binary ? "doc.badge.gearshape" : "doc.badge.ellipsis")
        } description: {
            Text("\(content.unreadableReason ?? "") (\(entry.sizeLabel))")
        } actions: {
            if let downloaded {
                ShareLink(item: downloaded) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
            } else {
                Button { Task { await download() } } label: {
                    if downloading { ProgressView() } else { Text("Baixar") }
                }
                .disabled(downloading)
            }
        }
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            downloaded = try await api.downloadFile(machine: machine, path: entry.path)
        } catch {
            reportaErro(error.localizedDescription)
        }
    }
}
