import SwiftUI

/// Abre — e edita — um arquivo da máquina. É a casca: carrega, guarda o estado,
/// decide para qual lado a tela vai e é dona da toolbar. Quem desenha o
/// conteúdo é `VisualizadorDeTexto` (texto) ou `VisualizadorBinario` (imagem,
/// vídeo, PDF, zip, e o texto que não coube).
///
/// A partição em três arquivos é de 12/08/2026 e não mudou comportamento: ela
/// existe para que a frente do preview e a frente do texto fossem escritas em
/// paralelo sem disputar o mesmo arquivo.
///
/// A edição só sobrescreve o arquivo aberto: não cria, não apaga, não move.
struct FileViewerView: View {
    let machine: String
    let entry: FileEntry
    /// A aba que contém esta tela está em foco? Só serve para o
    /// `VisualizadorBinario` parar a mídia — ver o comentário lá.
    var abaAtiva: Bool = true

    @State private var content: FileContent?
    @State private var error: String?
    /// Texto em edição. Só existe depois do load; `editing` liga o TextEditor.
    @State private var draft = ""
    @State private var editing = false
    @State private var saving = false
    /// Erro de salvar/baixar vira alerta: diferente do erro de abrir, a tela
    /// continua útil e não pode ser substituída pelo aviso.
    @State private var actionError: String?
    private let api = APIClient()

    /// Há mudança não salva? Só então o botão Salvar fica ativo.
    private var dirty: Bool { editing && draft != (content?.content ?? "") }

    var body: some View {
        Group {
            if let content {
                if !content.podeMostrarTexto {
                    VisualizadorBinario(machine: machine, entry: entry, content: content,
                                        abaAtiva: abaAtiva) { actionError = $0 }
                } else if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(4)
                } else {
                    VisualizadorDeTexto(entry: entry, content: content)
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
        // String variável, nunca `if/else` embrulhando o modifier: `abaAtiva`
        // muda em runtime (decisão #19 mantém toda máquina montada, e uma
        // subpasta empilhada por cima disso continua viva por baixo), e
        // embrulhar `.navigationTitle` num `if/else` remontaria esta view,
        // derrubando o `@State content/draft/editing` (mesma armadilha
        // documentada em `OwnedNavigationTitle.swift`).
        .navigationTitle(abaAtiva ? entry.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .alert("Deu ruim", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    /// [16/08/2026] Gate no CONTEÚDO da `ToolbarContent`, não num `if` na
    /// árvore do `body` — mesma regra do resto do app. Aqui é seguro além do
    /// de sempre: `toolbarItems` é `ToolbarContent`, uma DSL separada da
    /// árvore de `View`, então este `if abaAtiva` NUNCA remonta o `Group` que
    /// segura `@State content/draft/editing` acima. Antes deste gate,
    /// QUALQUER arquivo aberto em QUALQUER aba de máquina contribuía
    /// Editar/Compartilhar (ou Cancelar/Salvar) pra barra compartilhada,
    /// incondicionalmente — achado da auditoria do card de duplicação de
    /// toolbar (paleta/olho/ícone de máquina), não reportado ainda pela
    /// Vanessa mas mesma família estrutural.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if abaAtiva {
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
                // `isReadable` (e não `podeMostrarTexto`) é o portão certo aqui, e a
                // diferença entre os dois é a CAUDA: quando o hub manda só o fim de
                // um arquivo grande, a tela mostra o texto mas Editar e Compartilhar
                // somem — salvar 200 KB por cima de um arquivo de 5 MB o truncaria,
                // e compartilhar um pedaço com o nome do arquivo inteiro mentiria.
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
                                  binary: false, truncated: false, tail: nil, content: draft)
            editing = false
        } catch CutuqueError.notFound {
            actionError = "O arquivo não está mais lá (foi apagado ou virou pasta). Nada foi salvo."
        } catch {
            actionError = error.localizedDescription
        }
    }
}
