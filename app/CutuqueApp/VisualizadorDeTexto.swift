import SwiftUI

/// O lado "é texto" do visualizador de arquivos.
///
/// Nasceu de dentro do `FileViewerView` (12/08/2026) sem mudar comportamento: a
/// separação existe para que a frente do texto (markdown renderizado, JSON
/// formatado, realce, cauda) e a frente do preview pudessem ser escritas em
/// paralelo sem disputar o mesmo arquivo.
///
/// A regra que não se negocia aqui: o conteúdo-**fonte** (JSON indentado,
/// código, texto sem linguagem) sai num **único `Text`** com um
/// `AttributedString`. Quebrar em um `Text` por linha mataria a seleção — é o
/// bug que a leva do copiar acabou de consertar no chat.
///
/// O markdown **renderizado** é a exceção deliberada: reusa o `MarkdownText` do
/// chat como caixa-preta (um `Text` por bloco — título, parágrafo, lista...), e
/// é exatamente por isso que o botão "ver fonte" existe: é ele que devolve a
/// seleção do arquivo inteiro de uma vez, para quando o texto corrido do
/// markdown não bastar.
///
/// [31/08/2026] A segunda exceção é o **modo linha** (`modoLinha`): numeração e
/// busca precisam de uma âncora por linha, e não existe âncora dentro de um
/// `Text` só. Ela é sempre PEDIDA — ligar a numeração ou digitar na busca — e
/// some sozinha quando a busca é limpa, então o padrão do arquivo continua
/// sendo o `Text` inteiro com a seleção contínua.
struct VisualizadorDeTexto: View {
    let entry: FileEntry
    let content: FileContent

    /// Alterna entre o markdown renderizado e o fonte colorido. Não persiste
    /// entre arquivos de propósito — a Vanessa só pediu a alternância dentro de
    /// um arquivo, não memória dela entre arquivos — e não precisa de código
    /// para "esquecer": esta view nasce de novo a cada arquivo aberto (é um
    /// `FileViewerView` novo por navegação), então o estado já nasce limpo.
    @State private var verFonte = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Mesma chave do diff e do bloco de código do chat: "quão grande eu leio
    /// código neste aparelho" é uma pergunta só, feita em três telas.
    @AppStorage(TamanhoDeCodigo.chaveTelefone) private var fonteTelefone = TamanhoDeCodigo.padrao(pad: false)
    @AppStorage(TamanhoDeCodigo.chaveTablet) private var fonteTablet = TamanhoDeCodigo.padrao(pad: true)
    @AppStorage("cutuque.fonteNumeraLinhas") private var numeraLinhas = false
    @AppStorage("cutuque.fonteQuebraLinha") private var quebraLinha = false

    @State private var busca = ""
    @State private var indiceDaOcorrencia = 0

    private var isPadLayout: Bool { horizontalSizeClass == .regular }
    private var tamanhoDaFonte: Double { isPadLayout ? fonteTablet : fonteTelefone }
    private var fonteBinding: Binding<Double> { isPadLayout ? $fonteTablet : $fonteTelefone }
    private var buscaAtiva: String { busca.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// O texto do modo fonte já quebrado em linhas, e as linhas que casam com a
    /// busca — os dois em `@State`, calculados por mudança e não por render.
    ///
    /// Já foram propriedades computadas, e a conta saía três vezes por quadro
    /// (contador de linhas, barra de busca, corpo). Num arquivo grande isso é
    /// dividir megabytes a cada tecla digitada: aqui a divisão acontece uma vez
    /// por arquivo e a busca uma vez por termo.
    @State private var linhasDoFonte: [String] = []
    @State private var achados: [Int] = []

    /// A linha para onde a busca está apontando agora, se houver alguma.
    private var linhaAlvo: Int? {
        guard !achados.isEmpty else { return nil }
        return achados[BuscaEmTexto.indiceSeguro(indiceDaOcorrencia, total: achados.count)]
    }

    private func recalcularLinhas() {
        linhasDoFonte = Self.textoParaExibir(content.content, tipo: tipo).components(separatedBy: "\n")
        recalcularBusca()
    }

    private func recalcularBusca() {
        achados = BuscaEmTexto.linhasComOcorrencia(linhasDoFonte, termo: buscaAtiva)
        indiceDaOcorrencia = BuscaEmTexto.indiceSeguro(indiceDaOcorrencia, total: achados.count)
    }

    /// Modo linha: cada linha vira um `Text` próprio, com número à esquerda.
    ///
    /// **Isto contradiz de propósito a regra do topo do arquivo** (um `Text` só,
    /// para a seleção nativa atravessar o arquivo inteiro), e o critério para
    /// ligar é justamente que a usuária tenha PEDIDO algo que exige linha:
    /// numeração, ou uma busca em andamento — sem linha não há âncora para
    /// pular para a ocorrência nem lugar para pintar o achado. Fora desses dois
    /// casos o arquivo continua saindo num `Text` inteiro, e sair da busca
    /// devolve a seleção contínua sozinho.
    ///
    /// Duas coisas se perdem no modo linha e as duas são conscientes: a seleção
    /// para de atravessar linhas (para copiar tudo existem Compartilhar e a
    /// edição), e o realce passa a enxergar uma linha por vez — comentário de
    /// bloco e string multi-linha ficam sem cor a partir da segunda linha.
    private var modoLinha: Bool { numeraLinhas || !buscaAtiva.isEmpty }

    /// Como abrir, decidido pela extensão. `TipoDeArquivo` e o QuickLook leem a
    /// mesma pista, então as duas metades da tela nunca discordam.
    private var tipo: TipoDeArquivo { TipoDeArquivo.de(nome: entry.name) }

    /// `ehCauda` entra aqui — não só em `mostraFaixaDeCauda` — porque a cauda
    /// de um `.md` também muda QUAL modo é seguro mostrar, não só se há
    /// faixa de aviso. Ver o comentário em `RoteadorDeTexto.modo`.
    private var modo: ModoDeTexto {
        RoteadorDeTexto.modo(para: tipo, verFonte: verFonte, ehCauda: content.ehCauda)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Self.mostraFaixaDeCauda(content) {
                faixaDeCauda
            }
            // Cauda de markdown não tem o que alternar: `modo` já força fonte
            // (achado de revisão, 12/08/2026 — ver `RoteadorDeTexto.modo`), e
            // mostrar um botão "ver renderizado" que não faz nada seria pior
            // do que não mostrar botão nenhum.
            if tipo == .markdown && !content.ehCauda {
                alternadorDeFonte
            }
            if case .fonte = modo {
                barraDeCodigo
            }
            corpo
        }
        .onAppear { recalcularLinhas() }
        // O conteúdo troca sem a view morrer quando a cauda é recarregada.
        .onChange(of: content.content) { _, _ in recalcularLinhas() }
    }

    @ViewBuilder
    private var corpo: some View {
        switch modo {
        case .markdownRenderizado:
            // Só rolagem vertical: é prosa, quebra linha — nada de cortar uma
            // frase na borda da tela como faria o texto monoespaçado.
            ScrollView(.vertical) {
                MarkdownText(text: content.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .fonte(let linguagem):
            if modoLinha {
                fonteNumerado(linguagem)
            } else {
                ScrollView(quebraLinha ? .vertical : [.vertical, .horizontal]) {
                    Text(RealceDeSintaxe.aplicar(
                        Self.textoParaExibir(content.content, tipo: tipo),
                        linguagem: linguagem
                    ))
                    .font(.system(size: tamanhoDaFonte, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        }
    }

    /// Modo linha — ver `modoLinha` para o que ele troca e por quê.
    private func fonteNumerado(_ linguagem: Linguagem?) -> some View {
        let linhas = linhasDoFonte
        let marcadas = Set(achados)
        let alvo = linhaAlvo
        let calha = max(28, Double(String(linhas.count).count) * tamanhoDaFonte * TamanhoDeCodigo.razaoDeAvanco + 12)
        return ScrollViewReader { proxy in
            ScrollView(quebraLinha ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(linhas.enumerated()), id: \.offset) { indice, linha in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(indice + 1)")
                                .font(.system(size: max(9, tamanhoDaFonte - 1), design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: calha, alignment: .trailing)
                            Text(RealceDeSintaxe.aplicar(linha.isEmpty ? " " : linha, linguagem: linguagem))
                                .font(.system(size: tamanhoDaFonte, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: !quebraLinha, vertical: true)
                                .frame(maxWidth: quebraLinha ? .infinity : nil, alignment: .leading)
                            if !quebraLinha { Spacer(minLength: 0) }
                        }
                        .background(indice == alvo ? Color.yellow.opacity(0.28)
                                    : (marcadas.contains(indice) ? Color.yellow.opacity(0.12) : Color.clear))
                        .id(indice)
                    }
                }
                .padding(.vertical, 12)
                .padding(.trailing, 12)
            }
            .onChange(of: alvo) { _, novo in
                guard let novo else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(novo, anchor: .center) }
            }
        }
    }

    /// Fonte, numeração, quebra de linha e busca — o que transforma "dá para
    /// ver o arquivo" em "dá para achar o trecho".
    private var barraDeCodigo: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    numeraLinhas.toggle()
                } label: {
                    Image(systemName: numeraLinhas ? "list.number" : "list.bullet")
                }
                .accessibilityLabel(numeraLinhas ? "Esconder os números de linha" : "Numerar as linhas")

                Button {
                    quebraLinha.toggle()
                } label: {
                    Image(systemName: quebraLinha ? "text.alignleft" : "arrow.left.and.right")
                }
                .accessibilityLabel(quebraLinha ? "Desligar quebra de linha" : "Quebrar linhas longas")

                Spacer(minLength: 0)

                Text("\(linhasDoFonte.count) linhas")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                ControleDeTamanhoDeCodigo(tamanho: fonteBinding, mostraValor: isPadLayout)
            }
            .buttonStyle(.borderless)
            .font(.callout)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Buscar no arquivo", text: $busca)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: busca) { _, _ in
                        indiceDaOcorrencia = 0
                        recalcularBusca()
                    }
                if !buscaAtiva.isEmpty {
                    Text(BuscaEmTexto.rotulo(indice: indiceDaOcorrencia, achados: achados.count))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(achados.isEmpty ? .secondary : .primary)
                    Button {
                        indiceDaOcorrencia = BuscaEmTexto.anterior(indiceDaOcorrencia, total: achados.count)
                    } label: { Image(systemName: "chevron.up") }
                        .disabled(achados.isEmpty)
                        .accessibilityLabel("Ocorrência anterior")
                    Button {
                        indiceDaOcorrencia = BuscaEmTexto.proximo(indiceDaOcorrencia, total: achados.count)
                    } label: { Image(systemName: "chevron.down") }
                        .disabled(achados.isEmpty)
                        .accessibilityLabel("Próxima ocorrência")
                    Button {
                        busca = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Limpar a busca")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    /// Faixa de aviso quando o hub mandou só o **fim** do arquivo (12/08/2026 —
    /// cauda de texto grande). `entry.sizeLabel` é o tamanho TOTAL do arquivo,
    /// não o dos ~200 KiB que vieram — é o que dá o contraste de "isto não é
    /// tudo".
    private var faixaDeCauda: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.compact")
            Text("Mostrando só o fim do arquivo — tamanho total \(entry.sizeLabel)")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12))
    }

    /// Só o markdown tem o que alternar — os demais tipos já mostram a única
    /// forma que faz sentido para eles, então o controle nem aparece.
    private var alternadorDeFonte: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                verFonte.toggle()
            } label: {
                Label(
                    verFonte ? "Ver renderizado" : "Ver fonte",
                    systemImage: verFonte ? "doc.richtext" : "chevron.left.forwardslash.chevron.right"
                )
                .font(.footnote)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Puro (sem SwiftUI, testável direto)

    /// Só existe faixa quando o hub mandou a cauda. Outro motivo de o arquivo
    /// não ser editável (por exemplo, grande demais e SEM cauda — hub antigo)
    /// não é isso, e não pode herdar o aviso de "isto é só o fim" por engano.
    static func mostraFaixaDeCauda(_ content: FileContent) -> Bool { content.ehCauda }

    /// O texto que de fato vai para a tela no modo "fonte": igual ao conteúdo
    /// para a maioria dos tipos, e **indentado** para JSON. Separado do `body`
    /// para caber em XCTest sem montar SwiftUI.
    static func textoParaExibir(_ texto: String, tipo: TipoDeArquivo) -> String {
        tipo == .json ? IndentadorDeJSON.indentar(texto) : texto
    }
}

/// Como o conteúdo de um arquivo de texto deve ser exibido. Puro — nenhum tipo
/// de SwiftUI aqui — para o roteamento (".md vira renderizado", ".json e
/// código viram fonte colorida") ser testável sem montar tela.
enum ModoDeTexto: Equatable {
    /// `MarkdownText` do chat desenha; ver o comentário no topo do arquivo
    /// sobre por que este é o único modo com mais de um `Text`.
    case markdownRenderizado
    /// Único `Text` com `AttributedString`. `Linguagem?` é `nil` quando não há
    /// regra de realce — ainda sai monoespaçado, porque `RealceDeSintaxe`
    /// devolve sem cor nesse caso (não é responsabilidade desta view decidir
    /// isso duas vezes).
    case fonte(Linguagem?)
}

enum RoteadorDeTexto {
    /// `verFonte` só muda alguma coisa para markdown: nos demais tipos não
    /// existe alternância — não tem "fonte" e "renderizado" separados para um
    /// `.ts` ou um `.log`, então o parâmetro não é nem consultado fora do `.md`.
    ///
    /// `ehCauda` **sempre vence** `verFonte` para markdown (achado de revisão
    /// de 12/08/2026): a cauda é "os últimos ~200 KiB depois da primeira
    /// quebra de linha" — um corte cego, sem noção nenhuma de estrutura de
    /// markdown. Ela pode cair no meio de uma cerca de código (```) sem par
    /// ou de uma ênfase (`*`/`**`) sem fechamento vinda do trecho anterior que
    /// foi descartado, e o `MarkdownText` então interpreta o resto do
    /// arquivo como código ou engole parágrafos inteiros numa ênfase mal
    /// formada — um desenho bem diferente do fim real do arquivo, sem aviso
    /// nenhum além da faixa genérica de cauda. Mostrar sempre o fonte
    /// colorido evita esse resultado; a faixa de cauda já deixa claro que é
    /// um recorte, então o fonte é a leitura fiel disponível.
    static func modo(para tipo: TipoDeArquivo, verFonte: Bool, ehCauda: Bool = false) -> ModoDeTexto {
        if tipo == .markdown && ehCauda { return .fonte(.markdown) }
        if tipo == .markdown && !verFonte { return .markdownRenderizado }
        return .fonte(tipo.linguagemDoFonte)
    }
}

/// Indentação de JSON para leitura — função pura, isolada de propósito (pedido
/// explícito do desenho da leva: "isole a indentação numa função pura e
/// teste-a").
enum IndentadorDeJSON {
    /// JSON inválido **não é erro de tela**: um arquivo `.json` no meio de uma
    /// edição (vírgula sobrando, chave sem fechar) é o caso normal, não uma
    /// exceção — então volta como veio, cru, em vez de travar a tela com um
    /// aviso. Quem julga se o JSON malformado é grave é a usuária lendo, não
    /// esta função.
    ///
    /// **Validar e formatar são dois passos separados, de propósito** — achado
    /// de revisão de 12/08/2026: a versão anterior desta função usava
    /// `JSONSerialization` para as DUAS coisas (`jsonObject` pra virar
    /// `[String: Any]`/`NSDictionary`, depois `data(withJSONObject:)` pra
    /// reserializar). A ordem de iteração de um `Dictionary`/`NSDictionary` do
    /// Foundation **não é** a ordem do texto original — varia com o seed de
    /// hash de `String` do processo — então um `package.json` real saía com
    /// as chaves do topo (e as de dentro de `"scripts"`) em outra ordem a
    /// cada abertura. Reserializar também reescrevia número: `19.90` virava
    /// `19.899999999999999` (artefato de ponto flutuante), `0.0` virava `0`.
    /// Aqui `JSONSerialization` entra só para **validar** ("isto é JSON de
    /// verdade?"); quem formata é `reindentado(_:)`, que caminha sobre o
    /// TEXTO original — cada string, número e literal sai byte a byte como
    /// entrou, só com quebra de linha e indentação ao redor da pontuação
    /// estrutural (`{ } [ ] : ,`).
    static func indentar(_ texto: String) -> String {
        guard let dados = texto.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: dados, options: [.fragmentsAllowed])) != nil
        else { return texto }
        return reindentado(texto) ?? texto
    }

    /// Reformata um JSON já validado por `indentar`, preservando ordem de
    /// chave e a grafia literal de número (ver o comentário lá em cima).
    /// Caminha caractere a caractere sabendo só duas coisas: se está dentro
    /// de uma string — pra copiar o conteúdo sem reinterpretar, e pra não
    /// confundir um `{`/`:`/`,` que é DADO dentro da string com pontuação
    /// estrutural — e a profundidade de aninhamento, pra saber quantos
    /// espaços usar. Nunca reconstrói o valor: só reemite os mesmos
    /// caracteres ao redor da pontuação estrutural. Mesma filosofia do
    /// tokenizador do `RealceDeSintaxe`: dado, não reinterpretação.
    ///
    /// Devolve `nil` só se a profundidade fechar errado (mais `}`/`]` do que
    /// `{`/`[` abertos) — não deveria acontecer com texto que
    /// `JSONSerialization` já validou como JSON, mas é uma rede de segurança:
    /// melhor cair de volta pro texto cru (mesma regra do JSON inválido) do
    /// que arriscar uma indentação incoerente.
    private static func reindentado(_ texto: String) -> String? {
        let caracteres = Array(texto)
        let n = caracteres.count
        var saida = ""
        saida.reserveCapacity(n + n / 3)
        var profundidade = 0
        var i = 0

        func novaLinha(_ nivel: Int) {
            saida.append("\n")
            if nivel > 0 { saida.append(String(repeating: "  ", count: nivel)) }
        }

        while i < n {
            let c = caracteres[i]
            if c.isWhitespace {
                // Espaço/quebra de linha do texto original é ruído aqui — a
                // formatação inteira (onde quebra, quantos espaços) é
                // decidida por esta função, não herdada do arquivo de entrada.
                i += 1
                continue
            }
            switch c {
            case "\"":
                // Copia a string inteira, aspas incluídas, sem olhar pro que
                // tem dentro — é dado. `\` escapa o próximo caractere,
                // inclusive uma aspa, então uma aspa escapada nunca fecha a
                // string por engano.
                saida.append(c)
                i += 1
                var escapando = false
                while i < n {
                    let dentro = caracteres[i]
                    saida.append(dentro)
                    i += 1
                    if escapando { escapando = false; continue }
                    if dentro == "\\" { escapando = true; continue }
                    if dentro == "\"" { break }
                }
            case "{", "[":
                let fechamento: Character = (c == "{") ? "}" : "]"
                var j = i + 1
                while j < n, caracteres[j].isWhitespace { j += 1 }
                saida.append(c)
                if j < n, caracteres[j] == fechamento {
                    // Vazio: "{}" ou "[]" sem quebra de linha no meio.
                    saida.append(fechamento)
                    i = j + 1
                } else {
                    profundidade += 1
                    novaLinha(profundidade)
                    i += 1
                }
            case "}", "]":
                profundidade -= 1
                if profundidade < 0 { return nil }
                novaLinha(profundidade)
                saida.append(c)
                i += 1
            case ":":
                saida.append(": ")
                i += 1
            case ",":
                saida.append(",")
                novaLinha(profundidade)
                i += 1
            default:
                // Dígito de número, letra de true/false/null — sai como
                // veio, sem reformatar. É a garantia de "mesma grafia".
                saida.append(c)
                i += 1
            }
        }
        return profundidade == 0 ? saida : nil
    }
}
