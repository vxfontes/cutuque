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
    /// Falso quando embutida no `MachineDetailView`, que fica montado junto com
    /// o terminal e por isso é a ÚNICA fonte do título (ver
    /// `OwnedNavigationTitle.swift`). Default `true` preserva o empilhamento
    /// normal: subpasta continua dona do próprio título.
    var ownsNavigationTitle: Bool = true
    /// Falso quando o painel está escondido atrás do terminal. Só governa a
    /// toolbar: `.toolbar` compõe TODAS as views montadas, e `.opacity` não
    /// alcança a barra de navegação — sem isto o botão de ocultos apareceria
    /// com o terminal em foco.
    var isActive: Bool = true
    /// Portão de rede do `.task` abaixo (12/08/2026 — achado 2 da revisão
    /// adversarial da Task 5). Default `true` é o que preserva a navegação por
    /// pilha: entrar numa pasta empurra `FileBrowserView(machine:path:)` SEM
    /// este parâmetro, e pasta empilhada é sempre pasta que a usuária acabou de
    /// abrir — deve carregar. Quem passa `false` é só o `MachineDetailView`, a
    /// raiz montada dentro do `ZStack` de abas: com abas globais uma aba criada
    /// fica montada para sempre (decisão #19) e `.task` incondicional dispara
    /// UMA vez na criação, então N abas de máquina restauradas do disco no boot
    /// viravam N chamadas a `api.listFiles` de aba que a usuária nem está
    /// vendo — ver `MachineTerminalLifecycle.carregaArquivos`.
    var carregaAgora: Bool = true

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
        .ownedNavigationTitle(titulo, owns: ownsNavigationTitle)
        .toolbar {
            // Gate no CONTEÚDO, não no modificador: não é `if` na árvore de
            // views, então não remonta nada.
            if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $showHidden) {
                        Label("Ocultos", systemImage: showHidden ? "eye" : "eye.slash")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .overlay { if loading && listing == nil { ProgressView() } }
        .refreshable { await load() }
        .task(id: carregaAgora) {
            guard carregaAgora else { return }
            await load()
        }
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
            // Cancelamento NÃO é falha de rede. O `.task(id: carregaAgora)` acima
            // cancela o fetch em voo toda vez que o portão fecha — trocar de
            // painel (.files → .terminal) ou a aba perder o foco. A URLSession
            // devolve isso como URLError(.cancelled) e, sem este guarda, o alerta
            // "Não deu para listar" pipocava por NAVEGAÇÃO, numa aba que a usuária
            // já não está olhando (achado importante da revisão da fase D,
            // 12/08/2026 — o portão consertou a carga e criou este modo de falha).
            // Mesmo guarda que BoardView, TerminalMirrorView e PTYSession já usam.
            guard !Task.isCancelled, !ErroDeCarga.ehCancelamento(error) else { return }
            self.error = error.localizedDescription
        }
    }
}

/// Classifica o erro de uma carga cancelada. Vive aqui porque hoje só o
/// navegador de arquivos precisa dela; se outro chamador aparecer, promove pra
/// arquivo próprio. `Task.isCancelled` sozinho não basta: quando a Task já
/// morreu, a checagem no `catch` pode rodar fora dela, e o que sobra é o erro.
enum ErroDeCarga {
    static func ehCancelamento(_ erro: Error) -> Bool {
        if erro is CancellationError { return true }
        return (erro as? URLError)?.code == .cancelled
    }
}
