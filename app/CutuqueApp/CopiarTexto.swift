import SwiftUI
import UIKit

/// Copiar conteúdo para FORA do app — a usuária lendo o Cutuque no iPad sem
/// computador perto e querendo colar no WhatsApp.
///
/// O desenho não briga com nenhuma das três superfícies (chat picado em um `Text`
/// por bloco, espelho tmux que republica a cada quadro, SwiftTerm com o gesto
/// comido pelo mouse-reporting). Em vez disso: um toque copia a coisa inteira, e
/// quem quer um trecho abre `FolhaDeTexto`, um retrato IMÓVEL — nada muda embaixo
/// da seleção enquanto ela arrasta as alças.
/// Ver docs/superpowers/specs/2026-08-12-copiar-conteudo-design.md.
enum AreaDeTransferencia {
    static func copiar(_ texto: String) {
        UIPasteboard.general.string = texto
    }
}

/// O que EXATAMENTE vai para a área de transferência. Puro de propósito (padrão
/// da casa: decisão fora da View) — é aqui que mora o que faz o texto ser
/// colável, e um erro aqui a usuária só descobriria no WhatsApp.
enum TextoParaCopiar {

    /// Apara a cauda de espaço de cada linha e as linhas vazias do fim.
    ///
    /// Não é cosmético: a tela de um terminal é uma matriz 80x24 preenchida de
    /// espaço, então copiar cru cola um bloco com cauda invisível em toda linha e
    /// um punhado de linhas vazias no fim. Linha vazia no MEIO fica: parágrafo é
    /// informação. Espaço à ESQUERDA fica: indentação é conteúdo, código colado
    /// sem ela não roda.
    static func aparado(_ texto: String) -> String {
        var linhas = texto.components(separatedBy: "\n").map { linha in
            String(linha.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        while let ultima = linhas.last, ultima.isEmpty { linhas.removeLast() }
        return linhas.joined(separator: "\n")
    }

    /// A seleção da usuária quando ela conseguiu fazer uma; senão a tela toda.
    ///
    /// Existe porque no terminal ssh (SwiftTerm) às vezes a seleção nativa passa
    /// — quando passa, respeitar é melhor que ignorar. Vazio ou só espaço conta
    /// como "não selecionou".
    static func doTerminal(selecionado: String?, tela: String) -> String {
        if let selecionado {
            let limpo = aparado(selecionado)
            if !limpo.isEmpty { return limpo }
        }
        return aparado(tela)
    }

    /// Uma tool call como a usuária leria num terminal: o comando com `$` na
    /// frente e, embaixo, a saída. O que ela quer mandar não é "o comando" nem "o
    /// resultado" — é o par.
    ///
    /// Toma `String` em vez de `ChatItem` porque `ChatItem` é `private` dentro de
    /// `SessionDetailView.swift`; a regra sobre String é testável sem expor o
    /// tipo privado.
    static func deFerramenta(comando: String, resultado: String?) -> String {
        let cabeca = "$ " + aparado(comando)
        guard let resultado else { return cabeca }
        let corpo = aparado(resultado)
        return corpo.isEmpty ? cabeca : cabeca + "\n" + corpo
    }
}

/// Os links da tela, para copiar sem passar por alça de seleção nenhuma.
///
/// O pedido mais comum não é "esse texto", é "aquele link" — e caçar um link no
/// dedo, em fonte de terminal, é justamente o que não funciona. `NSDataDetector`
/// é o mesmo motor que o `UITextView` usa nos data detectors, então a lista do
/// topo da folha combina com o que fica tocável no corpo.
///
/// Medido antes de escrever, com as armadilhas de um terminal: o detector NÃO cai
/// em `script.sh`, `main.py`, `main.go`, `README.md`, `index.ts`, `package.json`
/// nem em caminho com barra. Pega `https://…`, `www.…` sem esquema e e-mail.
/// Passa `config.io` — falso positivo aceito de propósito: é uma linha a mais na
/// lista, não um erro no que vai ser colado.
enum LinksNoTexto {

    /// Os links achados, sem repetição e na ordem em que aparecem na tela.
    ///
    /// O que volta é o TRECHO como está escrito, não o `url.absoluteString`: para
    /// e-mail os dois divergem (`vanessa@example.com` vira `mailto:vanessa@…`), e
    /// o que ela quer colar no WhatsApp é o que ela está lendo.
    static func encontrar(_ texto: String) -> [String] {
        let fonte = desdobrado(texto)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let alcance = NSRange(fonte.startIndex..<fonte.endIndex, in: fonte)
        var vistos = Set<String>()
        var achados: [String] = []
        for achado in detector.matches(in: fonte, options: [], range: alcance) {
            guard let faixa = Range(achado.range, in: fonte) else { continue }
            let trecho = String(fonte[faixa])
            if vistos.insert(trecho).inserted { achados.append(trecho) }
        }
        return achados
    }

    /// Remonta a URL que a largura do terminal partiu no meio.
    ///
    /// `capture-pane` devolve uma GRADE: a linha que encheu a largura continua na
    /// próxima sem espaço nenhum entre as duas. No iPhone, onde cabem ~50 colunas,
    /// quase toda URL de verdade chega partida — sem remontar, a lista ofereceria
    /// meia URL, que colada não abre, e seria pior que não ter lista.
    ///
    /// A emenda é tímida de propósito, porque o risco simétrico é grudar parágrafo
    /// comum: só emenda quando a linha tem a MAIOR largura do bloco (numa grade,
    /// é o sinal de que ela transbordou) E termina dentro de uma URL. Prosa cuja
    /// linha cheia acaba em palavra normal fica intacta, e a emenda para no
    /// instante em que a URL acaba.
    static func desdobrado(_ texto: String) -> String {
        let linhas = texto.components(separatedBy: "\n")
        guard let largura = linhas.map({ $0.count }).max(), largura > 0 else { return texto }

        var saida: [String] = []
        var emenda = false
        for linha in linhas {
            if emenda, let ultima = saida.last {
                let junta = ultima + linha
                saida[saida.count - 1] = junta
                emenda = linha.count >= largura && terminaEmURL(junta)
            } else {
                saida.append(linha)
                emenda = linha.count >= largura && terminaEmURL(linha)
            }
        }
        return saida.joined(separator: "\n")
    }

    /// O último pedaço sem espaço da linha parece o começo de uma URL.
    private static func terminaEmURL(_ linha: String) -> Bool {
        guard let cauda = linha.split(whereSeparator: { $0 == " " || $0 == "\t" }).last
        else { return false }
        return cauda.contains("://") || cauda.hasPrefix("www.")
    }
}

/// Um retrato IMÓVEL do texto, onde a seleção funciona de verdade.
///
/// A imobilidade é o mecanismo, não um detalhe: `texto` é uma `String` já copiada
/// no instante do toque, então nem o `@Published` do espelho tmux nem o fluxo de
/// bytes do ssh mexem nela enquanto a usuária arrasta as alças.
///
/// [01/09/2026] O corpo deixou de ser um `Text` com `.textSelection(.enabled)`.
/// Dela: _"a opção de copiar textos específico eu não consigo selecionar texto
/// nenhum dentro, só consigo copiar tudo, então são duas opções pra mesma coisa"_.
/// A imobilidade era necessária e não era suficiente: a seleção do SwiftUI perde
/// três disputas de gesto empilhadas — o long-press-drag da seleção contra a
/// rolagem do `ScrollView`, e as duas contra o arrasto-pra-fechar do `.sheet` — e
/// em fonte de terminal as alças ainda são menores que o dedo. `UITextView`
/// desempata: rola sozinho (o `ScrollView` sai de cena), traz a seleção madura do
/// UIKit (duplo toque pega a palavra, "Selecionar" no menu) e liga os data
/// detectors, que fazem link virar link tocável com "Copiar link".
///
/// A lista de links em cima é o atalho para o caso que ela citou ("só quero um
/// link"): um toque copia, sem acertar alça nenhuma.
struct FolhaDeTexto: View {
    let titulo: String
    let texto: String
    var monoespacado: Bool = false

    @Environment(\.dismiss) private var dismiss

    private var links: [String] { LinksNoTexto.encontrar(texto) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !links.isEmpty {
                    ListaDeLinks(links: links)
                    Divider()
                }
                TextoSelecionavel(texto: texto, monoespacado: monoespacado)
            }
            .navigationTitle(titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BotaoDeCopiar(texto: texto, rotulo: "Copiar tudo")
                }
            }
        }
    }
}

/// O texto da folha num `UITextView`, que é onde a seleção do iOS é adulta.
///
/// Rola por conta própria de propósito: é o que tira o `ScrollView` do caminho e
/// acaba com a disputa de gesto que impedia a seleção. `dataDetectorTypes` só
/// funciona com `isEditable == false`, que é o caso — a folha é retrato, não
/// editor.
struct TextoSelecionavel: UIViewRepresentable {
    let texto: String
    var monoespacado: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let vista = UITextView()
        vista.isEditable = false
        vista.isSelectable = true
        vista.isScrollEnabled = true
        vista.alwaysBounceVertical = true
        vista.dataDetectorTypes = [.link]
        vista.backgroundColor = .clear
        vista.adjustsFontForContentSizeCategory = true
        vista.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        vista.textContainer.lineFragmentPadding = 0
        return vista
    }

    func updateUIView(_ vista: UITextView, context: Context) {
        // Só reescreve quando mudou: atribuir `text` joga a rolagem para o topo, e
        // a folha pode ser redesenhada por qualquer coisa (rotação, Dynamic Type)
        // enquanto ela está lendo o fim.
        if vista.text != texto { vista.text = texto }
        // Depois do texto: `text` novo não carrega a fonte de quem veio antes.
        vista.font = Self.fonte(monoespacado: monoespacado)
        vista.textColor = .label
    }

    /// Monoespaçada via `UIFontMetrics` e não `UIFont.monospacedSystemFont` no
    /// tamanho já escalado: o `adjustsFontForContentSizeCategory` só reescala
    /// fonte métrica, e sem isso a folha ignoraria o Dynamic Type dela.
    static func fonte(monoespacado: Bool) -> UIFont {
        guard monoespacado else { return UIFont.preferredFont(forTextStyle: .body) }
        let base = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)  // 13 = footnote
        return UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base)
    }
}

/// Os links achados, um toque cada.
///
/// Altura limitada: a folha é para ler o texto, então uma tela cheia de links não
/// pode empurrar o conteúdo para fora — a partir do quarto, a lista rola dentro
/// do próprio quadro.
private struct ListaDeLinks: View {
    let links: [String]

    private static let alturaDaLinha: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(links.count == 1 ? "1 link na tela" : "\(links.count) links na tela")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(links, id: \.self) { link in
                        LinhaDeLink(link: link)
                        if link != links.last {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(links.count, 3)) * Self.alturaDaLinha)
        }
    }
}

/// Um link e o retorno de que copiou. Mesmo motivo do `BotaoDeCopiar`: sem o
/// checkmark ela toca de novo sem saber se pegou.
private struct LinhaDeLink: View {
    let link: String

    @Environment(\.corDeDestaque) private var destaque
    @State private var copiado = false

    var body: some View {
        Button {
            AreaDeTransferencia.copiar(link)
            copiado = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                copiado = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                // Corta pelo MEIO: o começo diz o domínio e o fim diz qual página
                // é — cortar só o fim deixaria dez links iguais na tela.
                Text(link)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copiado ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(copiado ? Color.green : destaque)
            }
            .padding(.horizontal)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiado ? "Link copiado" : "Copiar link \(link)")
    }
}

/// Copia e diz que copiou. O retorno visual não é enfeite: sem ele a usuária não
/// tem como saber se pegou, toca de novo e fica na dúvida se colou o certo.
struct BotaoDeCopiar: View {
    let texto: String
    var rotulo: String? = nil

    @State private var copiado = false

    var body: some View {
        Button {
            AreaDeTransferencia.copiar(texto)
            copiado = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                copiado = false
            }
        } label: {
            // `if/else` e não um `.labelStyle(cond ? .iconOnly : .titleAndIcon)`:
            // os dois estilos são TIPOS concretos diferentes e o ternário não
            // tipa. O `@ViewBuilder` resolve sem ginástica.
            if let rotulo {
                Label(rotulo, systemImage: copiado ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copiado ? "checkmark" : "doc.on.doc")
            }
        }
        .disabled(TextoParaCopiar.aparado(texto).isEmpty)
        .accessibilityLabel(copiado ? "Copiado" : (rotulo ?? "Copiar"))
    }
}
