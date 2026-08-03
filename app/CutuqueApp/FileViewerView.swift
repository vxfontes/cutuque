import SwiftUI

/// Mostra — e edita — o conteúdo de um arquivo de texto da máquina. Binário ou
/// acima do teto de 1 MB não é renderizado: puxar bytes crus para a tela do
/// iPhone não ajuda ninguém, e o hub já manda esses casos marcados e sem
/// conteúdo. Nesses dois casos sobra o download, que traz o arquivo inteiro.
///
/// A edição só sobrescreve o arquivo aberto: não cria, não apaga, não move.
struct FileViewerView: View {
    let machine: String
    let entry: FileEntry

    @State private var content: FileContent?
    @State private var error: String?
    /// Texto em edição. Só existe depois do load; `editing` liga o TextEditor.
    @State private var draft = ""
    @State private var editing = false
    @State private var saving = false
    /// Arquivo baixado para o tmp, pronto para o ShareLink (binário/grande).
    @State private var downloaded: URL?
    @State private var downloading = false
    /// Erro de salvar/baixar vira alerta: diferente do erro de abrir, a tela
    /// continua útil e não pode ser substituída pelo aviso.
    @State private var actionError: String?
    private let api = APIClient()

    /// Há mudança não salva? Só então o botão Salvar fica ativo.
    private var dirty: Bool { editing && draft != (content?.content ?? "") }

    var body: some View {
        Group {
            if let content {
                if content.unreadableReason != nil {
                    unreadable(content)
                } else if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(4)
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
        .toolbar { toolbarItems }
        .alert("Deu ruim", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    /// Binário ou grande demais: o texto não vai aparecer, mas o arquivo inteiro
    /// ainda pode ser baixado.
    @ViewBuilder
    private func unreadable(_ content: FileContent) -> some View {
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

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if editing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancelar") {
                    draft = content?.content ?? ""
                    editing = false
                }
                .disabled(saving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if saving {
                    ProgressView()
                } else {
                    Button("Salvar") { Task { await save() } }.disabled(!dirty)
                }
            }
        } else if let content, content.isReadable {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Compartilhar o texto cobre "salvar no app Arquivos" sem uma
                // ida extra à máquina — o conteúdo já está aqui.
                ShareLink(item: content.content, preview: SharePreview(entry.name)) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button("Editar") {
                    draft = content.content
                    editing = true
                }
            }
        }
    }

    private func load() async {
        do {
            let fetched = try await api.readFile(machine: machine, path: entry.path)
            content = fetched
            draft = fetched.content
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let salvo = try await api.writeFile(machine: machine, path: entry.path, content: draft)
            // Reflete o que foi gravado sem reler a máquina: o size vem do hub.
            content = FileContent(path: salvo.path, size: salvo.size,
                                  binary: false, truncated: false, content: draft)
            editing = false
        } catch CutuqueError.notFound {
            actionError = "O arquivo não está mais lá (foi apagado ou virou pasta). Nada foi salvo."
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        do {
            downloaded = try await api.downloadFile(machine: machine, path: entry.path)
        } catch {
            actionError = error.localizedDescription
        }
    }
}
