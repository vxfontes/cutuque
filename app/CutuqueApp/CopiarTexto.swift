import SwiftUI
import UIKit

/// Copiar conteúdo para FORA do app — a usuária lendo o Cutuque no iPad sem
/// computador perto e querendo colar no WhatsApp.
///
/// O desenho não briga com nenhuma das três superfícies (chat picado em um `Text`
/// por bloco, espelho tmux que republica a cada quadro, SwiftTerm com o gesto
/// comido pelo mouse-reporting). Em vez disso: um toque copia a coisa inteira, e
/// quem quer um trecho abre `FolhaDeTexto`, um retrato IMÓVEL onde a seleção
/// nativa do iOS funciona porque nada muda embaixo dela.
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

/// Um retrato IMÓVEL do texto, onde a seleção nativa do iOS funciona.
///
/// A imobilidade é o mecanismo, não um detalhe: `texto` é uma `String` já copiada
/// no instante do toque, então nem o `@Published` do espelho tmux nem o fluxo de
/// bytes do ssh mexem nela enquanto a usuária arrasta as alças. Um `Text` só,
/// também de propósito: `.textSelection` não atravessa a fronteira entre dois
/// `Text` — é justamente por isso que a seleção não funciona no chat.
struct FolhaDeTexto: View {
    let titulo: String
    let texto: String
    var monoespacado: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Só vertical: com rolagem horizontal ligada, o `maxWidth: .infinity`
            // de baixo brigaria com a largura infinita do ScrollView. Linha
            // comprida de terminal quebra na tela — e isso não muda nada no que é
            // copiado, que é a String, não o layout.
            ScrollView(.vertical) {
                Text(texto)
                    .font(monoespacado ? .system(.footnote, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
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
