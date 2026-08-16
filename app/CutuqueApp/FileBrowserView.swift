import SwiftUI

/// Painel Arquivos da aba Máquinas: navega pastas e arquivos de um host. Pasta
/// abre outro nível; arquivo abre o visualizador. Ocultos escondidos por padrão,
/// com toggle — igual ao seletor de pastas.
///
/// [16/08/2026] Comentário antigo reescrito — card `2fc2b3f6` ("iPad/Arquivos:
/// não dá pra subir de pasta"). A versão anterior afirmava que "o voltar
/// nativo faz o papel do '..'"; isso é FALSO na prática. A pilha só tem UMA
/// direção: entrar empurra, voltar desfaz a ÚLTIMA descida — nunca sobe acima
/// do ponto onde a instância nasceu. No macmini a home cai perto de `/root`, e
/// dali não havia NENHUMA saída pra cima (nem pro `/DATA`, nem pra lugar
/// nenhum) — era exatamente esse fundo de poço que o comentário antigo não via.
///
/// A instância RAIZ (única com `empilhada == false`, ver `MachineDetailView`)
/// difere das empilhadas por construção: ela nasce direto no `ZStack` de abas
/// (decisão #19, nunca desmonta) e não tem pilha ABAIXO dela pra desempilhar —
/// por isso "subir" nela troca de pasta NO LUGAR (`caminhoAtual` recarrega,
/// igual `FolderPickerView.load(parent)`). Já uma instância empilhada só
/// existe porque uma pasta-mãe a empurrou ao tocar numa filha — logo o
/// pai-na-pilha é SEMPRE o pai-no-FS, e "subir" ali é `dismiss()` puro. "Voltar
/// sempre sobe": as duas afordâncias (linha ".." na lista + botão da toolbar)
/// chamam a mesma `subir()`, que escolhe entre os dois modos. Ver
/// `NavegacaoDePastas`, no fim do arquivo, pra "dá pra subir daqui?".
struct FileBrowserView: View {
    let machine: String
    /// Caminho de nascença. Vazio = home da máquina. Só serve pra semear
    /// `caminhoAtual` no `init` — depois disso a fonte de verdade é o
    /// `@State`, porque a instância raiz troca de pasta NO LUGAR (ver acima).
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
    /// A ABA que contém esta pilha está em foco (12/08/2026 — leva do preview).
    /// Só serve para o `FileViewerView` parar a mídia que estiver tocando, e
    /// por isso NÃO pode ser nenhum dos dois sinais que já existem aqui:
    /// `isActive` é a troca terminal/arquivos, e o `naTela` de que
    /// `carregaAgora` depende fica FALSO justamente quando o visualizador está
    /// empilhado por cima — ou seja, quando o vídeo está tocando. O único sinal
    /// que responde "a usuária ainda está olhando para esta aba?" é o
    /// `paneState`, que vem de fora.
    var abaAtiva: Bool = true
    /// Falso (default) = instância RAIZ, montada uma vez no `ZStack` de abas
    /// (`MachineDetailView.swift:115`), sem pilha abaixo dela — "subir" troca
    /// de pasta NO LUGAR. Verdadeiro = instância empilhada por um
    /// `NavigationLink` ao tocar numa subpasta (linha ~141 abaixo) — "subir"
    /// desempilha com `dismiss()`. Ver o comentário do topo do arquivo pra o
    /// porquê da assimetria.
    var empilhada: Bool = false

    @Environment(\.dismiss) private var dismiss
    /// Caminho realmente exibido/carregado. Semeado de `path` uma única vez no
    /// `init` (mesmo idioma de `MachineDetailView.init` com `_tema`/`_icone`) —
    /// não precisa de reseed porque nenhum call site do repo troca `path` sob
    /// a MESMA identidade SwiftUI (a raiz é fixada por `.id(machine.name)`; uma
    /// empilhada nasce e morre com um `path` fixo). Depois do `init`, é a ÚNICA
    /// fonte de verdade — `load()`, `titulo` e `podeSubir` leem daqui, nunca de
    /// `path`.
    @State private var caminhoAtual: String
    @State private var listing: FileListing?
    @State private var loading = false
    @State private var error: String?
    // Preferência pega em toda a navegação: destravar os ocultos uma vez vale
    // para as pastas seguintes.
    @AppStorage("machines.showHiddenFiles") private var showHidden = false
    private let api = APIClient()

    init(machine: String, path: String, ownsNavigationTitle: Bool = true,
         isActive: Bool = true, carregaAgora: Bool = true, abaAtiva: Bool = true,
         empilhada: Bool = false) {
        self.machine = machine
        self.path = path
        self.ownsNavigationTitle = ownsNavigationTitle
        self.isActive = isActive
        self.carregaAgora = carregaAgora
        self.abaAtiva = abaAtiva
        self.empilhada = empilhada
        _caminhoAtual = State(initialValue: path)
    }

    private var visible: [FileEntry] {
        listing?.visibleEntries(showHidden: showHidden) ?? []
    }

    /// Qual estado a lista vazia resolve pra — puro, ver `EstadoDaListaVazia`
    /// logo abaixo.
    private var estadoVazio: EstadoDaListaVazia {
        .resolver(visibleIsEmpty: visible.isEmpty, loading: loading, showHidden: showHidden)
    }

    /// "Dá pra subir daqui?" — puro, ver `NavegacaoDePastas` no fim do arquivo.
    /// Derivado de `listing`/`caminhoAtual` a cada render, nunca cacheado num
    /// `@State` à parte: com a decisão #19 (painel nunca desmonta), um cache
    /// separado do `listing` atual ficaria com a resposta errada ao trocar de
    /// pasta sem trocar de instância.
    private var podeSubir: Bool {
        NavegacaoDePastas.podeSubir(caminhoAtual: caminhoAtual, parent: listing?.parent)
    }

    /// Sobe um nível — fonte única pra linha ".." e pro botão da toolbar
    /// ("os dois", pedido explícito dela). Escolhe o modo pela mesma regra do
    /// comentário do topo: raiz troca no lugar, empilhada desempilha.
    private func subir() {
        guard podeSubir, let pai = listing?.parent else { return }
        if empilhada {
            dismiss()
        } else {
            caminhoAtual = pai
            Task { await load() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Legenda de local só na RAIZ (`!ownsNavigationTitle`): o título
            // nativo ali é fixo em `machine.name` (dono único é o
            // `MachineDetailView`, `OwnedNavigationTitle.swift`) e não
            // acompanha `caminhoAtual` trocando no lugar — sem isto, subir ou
            // descer na raiz não deixaria rastro nenhum de ONDE se está.
            // Empilhada não precisa: já é dona do próprio título (`titulo`
            // abaixo, mostrado na nav bar nativa).
            if !ownsNavigationTitle {
                Text(caminhoAtual.isEmpty ? machine : caminhoAtual)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            conteudo
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        Group {
            switch estadoVazio {
            case .comItens:
                lista
            case .talvezSoOcultos:
                // [16/08/2026] Antes, este ramo só diagnosticava ("talvez só
                // itens ocultos") e não resolvia — foi o que deixou a
                // navegação sem saída numa pasta só-de-ocultos: não dá pra
                // subir de pasta (bug maior, card 2fc2b3f6, ainda em aberto) e
                // a tela vazia não oferecia nada pra fazer. A ação mora AQUI,
                // junto do texto, porque é exatamente onde quem está travada
                // vai olhar — o toggle de ocultos já existia, mas só na
                // toolbar (abaixo), que é o que ela não olhou.
                //
                // `showHidden` é a MESMA preferência da toolbar (comentário na
                // declaração do `@AppStorage` acima — vale pra toda a
                // navegação): ligar por aqui tem que ter exatamente o mesmo
                // efeito de ligar por lá. Não é um estado paralelo, é o mesmo
                // `@AppStorage`.
                ContentUnavailableView {
                    Label("Nada visível aqui", systemImage: "eye.slash")
                } description: {
                    Text("Pode ser só itens ocultos nesta pasta.")
                } actions: {
                    Button("Mostrar ocultos") { showHidden = true }
                }
            case .semNadaMesmo:
                // Ocultos já ligados e mesmo assim vazia: a pasta está vazia
                // de verdade. Não há ação a oferecer — inventar um botão aqui
                // seria mentir sobre o que resolveria.
                ContentUnavailableView("Pasta vazia", systemImage: "folder")
            }
        }
        .ownedNavigationTitle(titulo, owns: ownsNavigationTitle)
        .toolbar {
            // Gate no CONTEÚDO, não no modificador: não é `if` na árvore de
            // views, então não remonta nada.
            //
            // [16/08/2026] `isActive` sozinho só cobre painel (terminal vs
            // arquivos) DENTRO de uma máquina — com decisão #19 (toda aba
            // montada pra sempre), duas abas de máquina ambas com o painel
            // Arquivos à frente tinham as DUAS `isActive == true`, dobrando o
            // ícone de olho na mesma navigation bar. `abaAtiva` (foco da ABA,
            // já recebido e repassado às subpastas — ver o comentário do
            // parâmetro) fecha o furo; `isActive` continua necessário porque
            // uma aba em foco com o terminal à frente não deve mostrar o
            // toggle de ocultos.
            if isActive && abaAtiva {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $showHidden) {
                        Label("Ocultos", systemImage: showHidden ? "eye" : "eye.slash")
                    }
                    .toggleStyle(.button)
                }
            }
            // [16/08/2026] Segunda afordância de subir (card 2fc2b3f6, ela
            // pediu "os dois"): a toolbar compõe INDEPENDENTE do `switch` em
            // `estadoVazio` acima, então este botão sobrevive aos três
            // estados — inclusive pasta vazia, que era o pior caso (sem
            // ISTO, a linha ".." sozinha sumiria justo ali, porque `lista` só
            // renderiza no ramo `.comItens`). `podeSubir` no próprio `if`
            // (mesma posição de `isActive && abaAtiva`) porque aqui o gate
            // não é foco de aba, é "existe pai pra onde ir" — mesmo lugar,
            // mesmo padrão da casa, só mais uma condição.
            if isActive && abaAtiva && podeSubir {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        subir()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
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

    /// A lista de verdade — extraída do `body` pra virar um dos ramos do
    /// `switch` em `estadoVazio`.
    @ViewBuilder
    private var lista: some View {
        List {
            // [16/08/2026] Primeira afordância de subir (card 2fc2b3f6, "os
            // dois"): só existe dentro do ramo `.comItens`, por isso o botão
            // da toolbar (acima) é indispensável pros outros dois ramos — não
            // é redundância, é cobertura dos três estados.
            if podeSubir {
                Button {
                    subir()
                } label: {
                    Label("..", systemImage: "arrow.up.left.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(visible) { entry in
                if entry.isDir {
                    NavigationLink {
                        FileBrowserView(machine: machine, path: entry.path, abaAtiva: abaAtiva, empilhada: true)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                            .lineLimit(1)
                            .foregroundStyle(entry.isHidden ? Color.secondary : Color.primary)
                    }
                } else {
                    NavigationLink {
                        FileViewerView(machine: machine, entry: entry, abaAtiva: abaAtiva)
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
            listing = try await api.listFiles(machine: machine, path: caminhoAtual)
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

/// O que a lista vazia de `FileBrowserView` deve mostrar. Puro — só os três
/// sinais que já existem na view (`visible.isEmpty`, `loading`, `showHidden`),
/// sem tocar rede nem `@AppStorage` — pra dar pra testar sem instanciar
/// SwiftUI (mesmo padrão de `ErroDeCarga`, acima).
enum EstadoDaListaVazia: Equatable {
    /// Não é o caso vazio: a lista tem item, ou ainda está carregando.
    case comItens
    /// Vazia só porque os ocultos estão escondidos — ligar o toggle pode
    /// revelar algo. Foi este o caso que deixou a navegação sem saída (card
    /// 2fc2b3f6): o texto avisava "talvez só ocultos" e não oferecia a ação.
    case talvezSoOcultos
    /// Ocultos já ligados e mesmo assim vazia: a pasta está vazia de verdade,
    /// não há ação a oferecer.
    case semNadaMesmo

    static func resolver(visibleIsEmpty: Bool, loading: Bool, showHidden: Bool) -> EstadoDaListaVazia {
        guard visibleIsEmpty, !loading else { return .comItens }
        return showHidden ? .semNadaMesmo : .talvezSoOcultos
    }
}

/// "Dá pra subir a partir daqui?" — puro, sem `@State` nem rede, pra testar
/// sem instanciar SwiftUI (mesmo padrão de `ErroDeCarga`/`EstadoDaListaVazia`,
/// acima). Card 2fc2b3f6.
///
/// NUNCA comparar contra "/" cravado — é a armadilha do precedente da casa em
/// `FolderPickerView.swift:35` (`listing.path != "/"`). O hub calcula `parent`
/// com `os.path.dirname` (`files.go:41`), e `dirname("/") == "/"`: a raiz do
/// FS é pai de si mesma. Comparar contra a string `"/"` cravada amarraria o
/// app a essa convenção de caminho (quebraria, por exemplo, num hub que
/// devolvesse raiz vazia ou `"C:\"`); comparar `parent` com o caminho atual
/// funciona em qualquer FS, porque a invariante ("pai de si mesmo") é do hub,
/// não do caractere `"/"`.
enum NavegacaoDePastas {
    /// `parent` vem de `listing?.parent` (`FileListing`, não-opcional no
    /// contrato — aqui opcional só porque `listing` pode ainda ser `nil`
    /// enquanto carrega).
    static func podeSubir(caminhoAtual: String, parent: String?) -> Bool {
        guard let parent, !parent.isEmpty else { return false }
        return parent != caminhoAtual
    }
}
