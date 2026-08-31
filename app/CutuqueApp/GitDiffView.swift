import SwiftUI

/// Painel nativo de alterações Git de uma máquina.
///
/// A view permanece montada junto com Terminal e Arquivos no iPad, mas o
/// request só nasce quando `isActive` é verdadeiro. Assim trocar de painel não
/// derruba o PTY nem dispara uma consulta por aba que a usuária ainda não viu.
///
/// ## O que mudou em 31/08/2026 (leva "o iPad no lugar do PC")
///
/// Antes esta tela era um `Text` com o diff inteiro colorido por ANSI e uma
/// lista de arquivos que não clicava. Dava para ver QUE mudou; não dava para
/// ler. Agora o texto passa pelo `DiffUnificado` e vira dado, o que destrava:
///
/// - lista de arquivos **clicável**, com `+N −M` por arquivo;
/// - **numeração de linha real** dos dois lados (antes/depois), que é o que
///   permite achar o trecho no editor sem contar linha no olho;
/// - **um arquivo por vez** na área de leitura — o que também é o que segura o
///   custo de tela num diff de 4 MiB;
/// - **busca** dentro do diff, com contagem por arquivo e pular de ocorrência
///   em ocorrência;
/// - **tamanho de fonte** e **quebra de linha**, lembrados por aparelho.
struct GitDiffView: View {
    let machine: String
    let isActive: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// `Color.accentColor` ignora o `.tint()` da raiz e volta azul de sistema —
    /// ver `BarreiraDeCorDeDestaqueTests`. O destaque do app vem daqui.
    @Environment(\.corDeDestaque) private var corDeDestaque
    @AppStorage private var savedDirectory: String
    @AppStorage(TamanhoDeCodigo.chaveTelefone) private var fonteTelefone: Double = TamanhoDeCodigo.padrao(pad: false)
    @AppStorage(TamanhoDeCodigo.chaveTablet) private var fonteTablet: Double = TamanhoDeCodigo.padrao(pad: true)
    /// Quebra de linha é a decisão oposta em cada aparelho: no iPhone a tela é
    /// estreita e rolar na horizontal a cada linha é insuportável; no iPad a
    /// tela cabe a linha inteira e preservar o alinhamento do código vale mais.
    @AppStorage("cutuque.diffQuebraLinha") private var quebraNoTelefone = true
    @AppStorage("cutuque.diffQuebraLinha.pad") private var quebraNoTablet = false

    @State private var directory: String
    @State private var draftDirectory: String
    @State private var reloadID = 0
    @State private var snapshot: GitDiff?
    @State private var arquivos: [DiffUnificado.Arquivo] = []
    @State private var selecionado: String?
    @State private var busca = ""
    @State private var indiceDaOcorrencia = 0
    /// Achados da busca por arquivo (caminho → ids de linha), calculados uma vez
    /// por termo e por carga — nunca por quadro.
    ///
    /// Antes a varredura era uma função chamada em TRÊS lugares do `body`: a
    /// contagem por arquivo na lista lateral, o "N/M" da barra e o destaque em
    /// `linhasDoDiff`. Como nada disso era cacheado, qualquer mudança de estado
    /// — pular para a próxima ocorrência, ligar a quebra de linha, mexer no
    /// tamanho da fonte — revarria o diff inteiro duas ou três vezes. Num diff
    /// perto do teto de 4 MiB isso é a interação travando a cada toque, exatamente
    /// no tamanho de diff que esta leva foi feita para aguentar. É a mesma
    /// correção que `VisualizadorDeTexto` já documenta ter recebido.
    @State private var achadosPorArquivo: [String: [Int]] = [:]
    @State private var error: String?

    private let api = APIClient()

    init(machine: String, isActive: Bool = true) {
        self.machine = machine
        self.isActive = isActive

        let key = Self.storageKey(machine: machine)
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        _savedDirectory = AppStorage(wrappedValue: stored, key)
        _directory = State(initialValue: stored)
        _draftDirectory = State(initialValue: stored)
    }

    private var isPadLayout: Bool { horizontalSizeClass == .regular }

    private var tamanhoDaFonte: Double { isPadLayout ? fonteTablet : fonteTelefone }

    private var fonteBinding: Binding<Double> { isPadLayout ? $fonteTablet : $fonteTelefone }

    private var quebraLinha: Bool { isPadLayout ? quebraNoTablet : quebraNoTelefone }

    /// Uma nova ativação do painel muda o id da task e atualiza o retrato.
    /// Digitar no campo não muda `directory` até confirmar, evitando um
    /// request a cada caractere.
    private var loadID: String {
        "\(isActive)-\(directory)-\(reloadID)"
    }

    static func storageKey(machine: String) -> String {
        "cutuque.machineGitDiffDir.\(machine)"
    }

    var body: some View {
        VStack(spacing: 0) {
            directoryBar

            Group {
                if let error {
                    errorContent(error)
                } else if let snapshot {
                    snapshotContent(snapshot)
                } else if directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyDirectoryContent
                } else {
                    loadingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: loadID) {
            await loadIfActive()
        }
        .onChange(of: busca) { _, _ in
            indiceDaOcorrencia = 0
            recalcularBusca()
        }
    }

    // MARK: - Barra da pasta

    private var directoryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            TextField("Pasta do repositório", text: $draftDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: isPadLayout ? 15 : 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submitDirectory)

            Button(action: submitDirectory) {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!isActive || draftDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Carregar diff")

            Button {
                reloadID += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!isActive || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Atualizar diff")
        }
        .padding(.horizontal, isPadLayout ? 20 : 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Estados sem conteúdo

    private var emptyDirectoryContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: isPadLayout ? 34 : 28))
                .foregroundStyle(.secondary)
            Text("Escolha uma pasta Git")
                .font(.headline)
            Text("Digite o caminho da pasta na máquina para ver as alterações.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Lendo o estado do repositório…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Não foi possível carregar o diff")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Tentar de novo") {
                reloadID += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isActive)
        }
        .padding()
    }

    // MARK: - Retrato

    @ViewBuilder
    private func snapshotContent(_ snapshot: GitDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(snapshot)

            if snapshot.truncated {
                Label("O diff é grande demais e foi cortado — os últimos arquivos podem faltar.",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, isPadLayout ? 20 : 12)
                    .padding(.bottom, 8)
            }

            let itens = itensDeArquivo(snapshot)
            if itens.isEmpty {
                semAlteracoes(snapshot)
            } else if isPadLayout {
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    listaDeArquivos(itens)
                        .frame(width: 300)
                    Divider()
                    painelDoArquivo(itens)
                }
            } else {
                Divider()
                VStack(spacing: 0) {
                    seletorCompacto(itens)
                    Divider()
                    painelDoArquivo(itens)
                }
            }
        }
    }

    private func summary(_ snapshot: GitDiff) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stateSymbol(snapshot.state))
                .foregroundStyle(stateColor(snapshot.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel(snapshot.state))
                    .font(.headline)
                Text(snapshot.root.isEmpty ? snapshot.dir : snapshot.root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if !snapshot.files.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(snapshot.files.count) arquivo\(snapshot.files.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    contadorDeLinhas(adicoes: arquivos.totalDeAdicoes, remocoes: arquivos.totalDeRemocoes)
                }
            }
        }
        .padding(.horizontal, isPadLayout ? 20 : 12)
        .padding(.vertical, 10)
    }

    private func contadorDeLinhas(adicoes: Int, remocoes: Int) -> some View {
        HStack(spacing: 6) {
            if adicoes > 0 {
                Text("+\(adicoes)").foregroundStyle(.green)
            }
            if remocoes > 0 {
                Text("−\(remocoes)").foregroundStyle(.red)
            }
        }
        .font(.caption2.monospacedDigit().weight(.medium))
    }

    private func semAlteracoes(_ snapshot: GitDiff) -> some View {
        VStack(spacing: 10) {
            Image(systemName: snapshot.state == "clean" ? "checkmark.seal" : "questionmark.folder")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(snapshot.state == "clean" ? "Nada alterado por aqui" : stateLabel(snapshot.state))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Lista de arquivos

    /// Uma linha da lista. Junta o que o `git status` sabe (inclusive arquivo
    /// não rastreado, que NÃO aparece no diff) com o que o diff traz (hunks e
    /// contagem). Um dos dois lados pode faltar, e é justamente aí que a tela
    /// antiga confundia: arquivo novo aparecia na lista e o diff era vazio.
    struct ItemDeArquivo: Identifiable {
        let id: String
        let status: GitFileChange?
        let diff: DiffUnificado.Arquivo?

        var caminho: String { id }
        var nomeCurto: String { id.split(separator: "/").last.map(String.init) ?? id }
        var pasta: String {
            let partes = id.split(separator: "/")
            guard partes.count > 1 else { return "" }
            return partes.dropLast().joined(separator: "/")
        }
    }

    private func itensDeArquivo(_ snapshot: GitDiff) -> [ItemDeArquivo] {
        var porCaminho: [String: GitFileChange] = [:]
        for f in snapshot.files { porCaminho[f.path] = f }

        var itens: [ItemDeArquivo] = arquivos.map {
            ItemDeArquivo(id: $0.caminho, status: porCaminho[$0.caminho], diff: $0)
        }
        let jaTem = Set(itens.map(\.id))
        // O que o status viu e o diff não traz: arquivo não rastreado, e também
        // qualquer coisa que tenha caído fora do corte quando `truncated`.
        for f in snapshot.files where !jaTem.contains(f.path) {
            itens.append(ItemDeArquivo(id: f.path, status: f, diff: nil))
        }
        return itens
    }

    private func listaDeArquivos(_ itens: [ItemDeArquivo]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                let atual = selecaoEfetiva(entre: itens)
                ForEach(itens) { item in
                    Button {
                        selecionar(item.id)
                    } label: {
                        linhaDaLista(item, escolhido: item.id == atual)
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func linhaDaLista(_ item: ItemDeArquivo, escolhido: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(letraDeStatus(item))
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(corDeStatus(item))
                .frame(width: 14, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.nomeCurto)
                    .font(.caption.weight(escolhido ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.pasta.isEmpty {
                    Text(item.pasta)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                if let d = item.diff {
                    contadorDeLinhas(adicoes: d.adicoes, remocoes: d.remocoes)
                }
                if !buscaAtiva.isEmpty {
                    let n = ocorrencias(em: item)
                    if n > 0 {
                        Text("\(n)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(corDeDestaque.opacity(0.22), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(escolhido ? corDeDestaque.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }

    /// iPhone: a lista inteira não cabe ao lado, então vira um menu com o
    /// arquivo atual + setas de anterior/próximo (uma mão só).
    private func seletorCompacto(_ itens: [ItemDeArquivo]) -> some View {
        let atual = selecaoEfetiva(entre: itens)
        let indice = itens.firstIndex { $0.id == atual } ?? 0
        return HStack(spacing: 8) {
            Button {
                selecionar(itens[max(0, indice - 1)].id)
            } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(indice == 0)
                .accessibilityLabel("Arquivo anterior")

            Menu {
                ForEach(itens) { item in
                    Button {
                        selecionar(item.id)
                    } label: {
                        Label("\(letraDeStatus(item))  \(item.caminho)",
                              systemImage: item.id == atual ? "checkmark" : "doc")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(itens[indice].nomeCurto)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let d = itens[indice].diff {
                        contadorDeLinhas(adicoes: d.adicoes, remocoes: d.remocoes)
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }

            Text("\(indice + 1)/\(itens.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                selecionar(itens[min(itens.count - 1, indice + 1)].id)
            } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(indice >= itens.count - 1)
                .accessibilityLabel("Próximo arquivo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Painel do arquivo escolhido

    @ViewBuilder
    private func painelDoArquivo(_ itens: [ItemDeArquivo]) -> some View {
        let atual = selecaoEfetiva(entre: itens)
        let item = itens.first { $0.id == atual } ?? itens[0]
        VStack(spacing: 0) {
            barraDoArquivo(item)
            Divider()
            conteudoDoArquivo(item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func barraDoArquivo(_ item: ItemDeArquivo) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(item.caminho)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                if let antigo = item.diff?.caminhoAntigo {
                    Text("← \(antigo)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)

                Button {
                    AreaDeTransferencia.copiar(textoCruDo(item))
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(item.diff == nil)
                .accessibilityLabel("Copiar o diff deste arquivo")

                Button {
                    if isPadLayout { quebraNoTablet.toggle() } else { quebraNoTelefone.toggle() }
                } label: {
                    Image(systemName: quebraLinha ? "text.alignleft" : "arrow.left.and.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(quebraLinha ? "Desligar quebra de linha" : "Quebrar linhas longas")

                ControleDeTamanhoDeCodigo(tamanho: fonteBinding, mostraValor: isPadLayout)
            }

            barraDeBusca(item)
        }
        .padding(.horizontal, isPadLayout ? 14 : 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func barraDeBusca(_ item: ItemDeArquivo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Buscar no diff", text: $busca)
                .textFieldStyle(.plain)
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !buscaAtiva.isEmpty {
                let achados = linhasComOcorrencia(item)
                Text(achados.isEmpty ? "0" : "\(BuscaEmTexto.indiceSeguro(indiceDaOcorrencia, total: achados.count) + 1)/\(achados.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(achados.isEmpty ? .secondary : .primary)
                // Circular, como no visualizador de arquivos: quem chega na
                // última e aperta "próxima" quer a primeira, não um botão
                // apagado. Duas buscas na mesma tela com comportamento
                // diferente é pior que qualquer uma das duas escolhas.
                Button {
                    indiceDaOcorrencia = BuscaEmTexto.anterior(indiceDaOcorrencia, total: achados.count)
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(achados.isEmpty)
                    .accessibilityLabel("Ocorrência anterior")
                Button {
                    indiceDaOcorrencia = BuscaEmTexto.proximo(indiceDaOcorrencia, total: achados.count)
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(achados.isEmpty)
                    .accessibilityLabel("Próxima ocorrência")
                Button {
                    busca = ""
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Limpar a busca")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func conteudoDoArquivo(_ item: ItemDeArquivo) -> some View {
        if let arquivo = item.diff, !arquivo.hunks.isEmpty {
            linhasDoDiff(arquivo, item: item)
        } else {
            avisoSemDiff(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func avisoSemDiff(_ item: ItemDeArquivo) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item.diff?.binario == true ? "doc.viewfinder" : "sparkles")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(mensagemSemDiff(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 30)
    }

    private func mensagemSemDiff(_ item: ItemDeArquivo) -> String {
        if item.diff?.binario == true { return "Arquivo binário — o git não gera diff de linhas para ele." }
        if item.status?.worktree == "untracked" {
            return "Arquivo novo, ainda fora do controle do git. Ele só ganha diff depois de um `git add`."
        }
        if snapshot?.truncated == true { return "Este arquivo ficou fora do pedaço de diff que coube na resposta." }
        return "Sem alteração de conteúdo neste arquivo (pode ser só mudança de permissão ou de nome)."
    }

    private func linhasDoDiff(_ arquivo: DiffUnificado.Arquivo, item: ItemDeArquivo) -> some View {
        let achados = linhasComOcorrencia(item)
        let alvo = achados.isEmpty ? nil : achados[BuscaEmTexto.indiceSeguro(indiceDaOcorrencia, total: achados.count)]
        let largura = larguraDoConteudo(arquivo)
        return ScrollViewReader { proxy in
            ScrollView(quebraLinha ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(arquivo.hunks) { hunk in
                        cabecalhoDeHunk(hunk, largura: largura)
                        ForEach(hunk.linhas) { linha in
                            linhaDeDiff(linha, largura: largura, destacada: linha.id == alvo)
                                .id(linha.id)
                        }
                    }
                    // Uma folga no fim para a última linha não ficar colada na
                    // borda inferior quando se rola até o fim.
                    Color.clear.frame(height: 24)
                }
            }
            .background(Color(.systemBackground))
            .onChange(of: alvo) { _, novo in
                guard let novo else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(novo, anchor: .center) }
            }
            .onChange(of: item.id) { _, _ in
                guard let primeira = arquivo.hunks.first?.linhas.first?.id else { return }
                proxy.scrollTo(primeira, anchor: .top)
            }
        }
    }

    private func cabecalhoDeHunk(_ hunk: DiffUnificado.Hunk, largura: Double) -> some View {
        HStack(spacing: 8) {
            Text(hunk.cabecalho)
                .foregroundStyle(.teal)
            if !hunk.contexto.isEmpty {
                Text(hunk.contexto)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: tamanhoDaFonte, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: quebraLinha ? 0 : largura, alignment: .leading)
        .background(Color.teal.opacity(0.10))
    }

    private func linhaDeDiff(_ linha: DiffUnificado.Linha, largura: Double, destacada: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            numeroDeLinha(linha.antiga)
            numeroDeLinha(linha.nova)
            Text(marcador(linha.tipo))
                .font(.system(size: tamanhoDaFonte, design: .monospaced))
                .foregroundStyle(corDoTexto(linha.tipo))
                .frame(width: tamanhoDaFonte * 0.9, alignment: .leading)
            Text(linha.texto.isEmpty ? " " : linha.texto)
                .font(.system(size: tamanhoDaFonte, design: .monospaced))
                .foregroundStyle(corDoTexto(linha.tipo))
                .fixedSize(horizontal: !quebraLinha, vertical: true)
                .frame(maxWidth: quebraLinha ? .infinity : nil, alignment: .leading)
            if !quebraLinha { Spacer(minLength: 0) }
        }
        .padding(.trailing, 8)
        .frame(minWidth: quebraLinha ? 0 : largura, alignment: .leading)
        .background(fundoDaLinha(linha.tipo, destacada: destacada))
    }

    private func numeroDeLinha(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: max(9, tamanhoDaFonte - 1), design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: larguraDaCalha, alignment: .trailing)
            .padding(.trailing, 6)
    }

    // MARK: - Cores e rótulos

    private func marcador(_ tipo: DiffUnificado.TipoDeLinha) -> String {
        switch tipo {
        case .adicao: return "+"
        case .remocao: return "−"
        case .contexto: return " "
        case .meta: return " "
        }
    }

    private func corDoTexto(_ tipo: DiffUnificado.TipoDeLinha) -> Color {
        switch tipo {
        case .adicao: return .green
        case .remocao: return .red
        case .contexto: return .primary
        case .meta: return .secondary
        }
    }

    private func fundoDaLinha(_ tipo: DiffUnificado.TipoDeLinha, destacada: Bool) -> Color {
        if destacada { return Color.yellow.opacity(0.28) }
        switch tipo {
        case .adicao: return Color.green.opacity(0.12)
        case .remocao: return Color.red.opacity(0.12)
        case .contexto, .meta: return .clear
        }
    }

    // MARK: - Busca

    private var buscaAtiva: String {
        busca.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ocorrencias(em item: ItemDeArquivo) -> Int {
        linhasComOcorrencia(item).count
    }

    /// Ids das linhas que casam com a busca, na ordem em que aparecem. É o que
    /// alimenta tanto o contador quanto o pular de ocorrência em ocorrência.
    /// Só lê o cache — quem varre é `recalcularBusca()`.
    private func linhasComOcorrencia(_ item: ItemDeArquivo) -> [Int] {
        achadosPorArquivo[item.id] ?? []
    }

    /// Varre o diff inteiro uma vez e guarda os ids que casam, por arquivo.
    ///
    /// Delega para `BuscaEmTexto`, que é o que o cabeçalho daquele arquivo
    /// promete ("nasceu para o visualizador de arquivos e para o diff"). A
    /// implementação que existia aqui usava `localizedCaseInsensitiveContains`,
    /// sensível a acento: buscar "funcao" achava `função` no visualizador e não
    /// achava no diff, na mesma tela e no mesmo dia. Uma busca só, uma regra só.
    private func recalcularBusca() {
        let alvo = buscaAtiva
        guard !alvo.isEmpty else {
            achadosPorArquivo = [:]
            return
        }
        var mapa: [String: [Int]] = [:]
        for arquivo in arquivos {
            let linhas = arquivo.hunks.flatMap(\.linhas)
            let indices = BuscaEmTexto.linhasComOcorrencia(linhas.map(\.texto), termo: alvo)
            guard !indices.isEmpty else { continue }
            mapa[arquivo.caminho] = indices.map { linhas[$0].id }
        }
        achadosPorArquivo = mapa
    }

    // MARK: - Seleção

    /// Qual arquivo mostrar. `selecionado` pode estar apontando para um arquivo
    /// que sumiu no recarregamento (foi commitado, por exemplo) — nesse caso o
    /// primeiro da lista assume, em vez de a área de leitura ficar vazia sem
    /// explicação.
    private func selecaoEfetiva(entre itens: [ItemDeArquivo]) -> String {
        if let selecionado, itens.contains(where: { $0.id == selecionado }) { return selecionado }
        return itens.first?.id ?? ""
    }

    private func selecionar(_ caminho: String) {
        selecionado = caminho
        indiceDaOcorrencia = 0
    }

    private func letraDeStatus(_ item: ItemDeArquivo) -> String {
        guard let file = item.status else { return item.diff?.binario == true ? "B" : "M" }
        let value = file.worktree == "unchanged" ? file.index : file.worktree
        switch value {
        case "added": return "A"
        case "deleted": return "D"
        case "renamed": return "R"
        case "copied": return "C"
        case "conflicted": return "!"
        case "modified": return "M"
        case "untracked": return "?"
        default: return "·"
        }
    }

    private func corDeStatus(_ item: ItemDeArquivo) -> Color {
        switch letraDeStatus(item) {
        case "A", "?": return .green
        case "D": return .red
        case "!": return .orange
        case "R", "C": return .blue
        default: return .secondary
        }
    }

    // MARK: - Texto para fora do app

    /// Reconstrói o diff do arquivo no formato unificado — é o que a pessoa
    /// espera colar num `git apply`, num chat ou numa mensagem.
    private func textoCruDo(_ item: ItemDeArquivo) -> String {
        guard let arquivo = item.diff else { return item.caminho }
        var linhas: [String] = ["--- a/\(arquivo.caminhoAntigo ?? arquivo.caminho)", "+++ b/\(arquivo.caminho)"]
        for hunk in arquivo.hunks {
            linhas.append(hunk.cabecalho)
            for linha in hunk.linhas {
                switch linha.tipo {
                case .adicao: linhas.append("+" + linha.texto)
                case .remocao: linhas.append("-" + linha.texto)
                case .contexto: linhas.append(" " + linha.texto)
                case .meta: linhas.append(linha.texto)
                }
            }
        }
        return linhas.joined(separator: "\n")
    }

    /// Largura em pontos que a linha mais longa do arquivo ocupa. Sem isto, com
    /// a quebra de linha desligada, cada linha teria a largura do próprio texto
    /// e o fundo verde/vermelho ficaria serrilhado, terminando em lugar
    /// diferente a cada linha.
    private func larguraDoConteudo(_ arquivo: DiffUnificado.Arquivo) -> Double {
        guard !quebraLinha else { return 0 }
        return TamanhoDeCodigo.larguraDeTexto(colunas: arquivo.maiorColuna, tamanho: tamanhoDaFonte)
            + 2 * larguraDaCalha + 24
    }

    /// Largura de cada uma das duas colunas de número de linha. Sai daqui e não
    /// de um literal porque a conta da largura total precisa da mesma medida.
    private var larguraDaCalha: Double { max(30, tamanhoDaFonte * 2.6) }

    // MARK: - Carga

    private func submitDirectory() {
        let value = draftDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        directory = value
        savedDirectory = value
        snapshot = nil
        arquivos = []
        selecionado = nil
        error = nil
        reloadID += 1
    }

    private func loadIfActive() async {
        guard isActive else { return }
        let requestedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedDirectory.isEmpty else { return }

        error = nil
        do {
            var loaded = try await api.gitDiff(machine: machine, dir: requestedDirectory)
            try Task.checkCancellation()
            // O parse pode varrer alguns MiB de texto: sai da main actor para
            // não segurar a tela — o painel do iPad fica montado o tempo todo
            // (decisão #19), então travar aqui trava também o terminal ao lado.
            let texto = loaded.diff
            let parseados = await Task.detached(priority: .userInitiated) {
                DiffUnificado.parse(texto)
            }.value
            try Task.checkCancellation()
            guard isActive, directory.trimmingCharacters(in: .whitespacesAndNewlines) == requestedDirectory else {
                return
            }
            // O texto cru já virou `arquivos`; guardá-lo junto duplicaria até
            // 4 MiB (o teto novo do hub) pelo resto da vida do painel — e no
            // iPad o painel de diff fica montado o tempo todo (decisão #19),
            // então "resto da vida" é enquanto a aba existir. Nada depois daqui
            // lê `snapshot.diff`.
            loaded.diff = ""
            snapshot = loaded
            arquivos = parseados
            recalcularBusca()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "clean": return "Repositório limpo"
        case "not_a_repository": return "Não é um repositório Git"
        case "changes": return "Alterações locais"
        default: return state.isEmpty ? "Estado desconhecido" : state
        }
    }

    private func stateSymbol(_ state: String) -> String {
        switch state {
        case "clean": return "checkmark.circle"
        case "not_a_repository": return "questionmark.folder"
        case "changes": return "circle.lefthalf.filled"
        default: return "questionmark.circle"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "clean": return .green
        case "not_a_repository": return .secondary
        case "changes": return .orange
        default: return .secondary
        }
    }
}
