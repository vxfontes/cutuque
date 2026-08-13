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
struct VisualizadorDeTexto: View {
    let entry: FileEntry
    let content: FileContent

    /// Alterna entre o markdown renderizado e o fonte colorido. Não persiste
    /// entre arquivos de propósito — a Vanessa só pediu a alternância dentro de
    /// um arquivo, não memória dela entre arquivos — e não precisa de código
    /// para "esquecer": esta view nasce de novo a cada arquivo aberto (é um
    /// `FileViewerView` novo por navegação), então o estado já nasce limpo.
    @State private var verFonte = false

    /// Como abrir, decidido pela extensão. `TipoDeArquivo` e o QuickLook leem a
    /// mesma pista, então as duas metades da tela nunca discordam.
    private var tipo: TipoDeArquivo { TipoDeArquivo.de(nome: entry.name) }

    private var modo: ModoDeTexto { RoteadorDeTexto.modo(para: tipo, verFonte: verFonte) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Self.mostraFaixaDeCauda(content) {
                faixaDeCauda
            }
            if tipo == .markdown {
                alternadorDeFonte
            }
            corpo
        }
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
            ScrollView([.vertical, .horizontal]) {
                Text(RealceDeSintaxe.aplicar(
                    Self.textoParaExibir(content.content, tipo: tipo),
                    linguagem: linguagem
                ))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
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
    static func modo(para tipo: TipoDeArquivo, verFonte: Bool) -> ModoDeTexto {
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
    static func indentar(_ texto: String) -> String {
        guard let dados = texto.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados, options: [.fragmentsAllowed]),
              let saida = try? JSONSerialization.data(
                withJSONObject: objeto,
                options: [.prettyPrinted, .fragmentsAllowed]
              ),
              let indentado = String(data: saida, encoding: .utf8)
        else { return texto }
        return indentado
    }
}
