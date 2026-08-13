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
