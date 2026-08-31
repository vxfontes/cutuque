import SwiftUI

/// Tamanho da fonte monoespaçada das telas de LEITURA de código — diff, preview
/// de arquivo e blocos de código do chat.
///
/// Existe como tipo próprio (e não como três `@AppStorage` soltos) por dois
/// motivos concretos:
///
///  1. **O aparelho muda o padrão, não a preferência.** 11 pt no iPhone e 13 pt
///     no iPad são pontos de partida diferentes porque a tela é diferente; o
///     ajuste dela, uma vez feito, é dela. Por isso são duas chaves separadas
///     (`…codigoFonte` e `…codigoFonte.pad`), como o terminal já fazia com
///     `cutuque.terminalFont`/`cutuque.terminalFont.pad`.
///  2. **A conta de largura precisa ser a mesma em todo lugar.** Sem quebra de
///     linha, o diff precisa saber quão largo é o texto para o fundo de cada
///     linha ir até o fim — e essa conta depende do tamanho da fonte. Deixá-la
///     junto do tamanho evita duas fórmulas divergindo.
///
/// Lógica pura, sem View: cabe em XCTest como o resto (`ComposerEnter`,
/// `LayoutRuleGate`, `RoteadorDeTexto`…).
enum TamanhoDeCodigo {
    /// Abaixo disto o texto some no iPhone; acima, sobra uma dúzia de colunas
    /// por tela e ler código vira rolagem horizontal sem fim.
    static let minimo: Double = 9
    static let maximo: Double = 24
    static let passo: Double = 1

    static let chaveTelefone = "cutuque.codigoFonte"
    static let chaveTablet = "cutuque.codigoFonte.pad"

    static func padrao(pad: Bool) -> Double { pad ? 13 : 11 }

    /// Aplica um passo e mantém dentro da faixa. Nunca sai da faixa nem em
    /// chamada repetida — é o que deixa o botão A+/A− ser só um `+= passo`.
    static func ajustado(_ atual: Double, por delta: Double) -> Double {
        min(maximo, max(minimo, atual + delta))
    }

    static func podeAumentar(_ atual: Double) -> Bool { atual < maximo }
    static func podeDiminuir(_ atual: Double) -> Bool { atual > minimo }

    /// Largura aproximada de UM caractere na monoespaçada do sistema.
    ///
    /// 0,6 é a razão avanço/corpo do SF Mono (e da maioria das monoespaçadas de
    /// texto). Não precisa ser exata: quem usa isto é o cálculo da largura
    /// mínima da linha do diff, e errar para mais só deixa um rabo de fundo
    /// colorido depois do texto — errar para menos é que cortaria o fundo antes
    /// do fim da linha. Por isso a margem embutida no `larguraDeTexto`.
    static let razaoDeAvanco: Double = 0.6

    /// Largura em pontos para caber `colunas` caracteres, com uma folga de duas
    /// colunas para não faltar por arredondamento.
    static func larguraDeTexto(colunas: Int, tamanho: Double) -> Double {
        Double(colunas + 2) * tamanho * razaoDeAvanco
    }
}

/// Par de botões A− / A+ para as telas de leitura de código. Fica aqui junto do
/// tipo que ele mexe para não haver duas cópias do mesmo par com faixas
/// diferentes.
struct ControleDeTamanhoDeCodigo: View {
    @Binding var tamanho: Double
    /// Compacto no iPhone (só os dois botões), com o valor no meio no iPad.
    var mostraValor = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                tamanho = TamanhoDeCodigo.ajustado(tamanho, por: -TamanhoDeCodigo.passo)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(!TamanhoDeCodigo.podeDiminuir(tamanho))
            .accessibilityLabel("Diminuir a fonte")

            if mostraValor {
                Text("\(Int(tamanho))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18)
            }

            Button {
                tamanho = TamanhoDeCodigo.ajustado(tamanho, por: TamanhoDeCodigo.passo)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(!TamanhoDeCodigo.podeAumentar(tamanho))
            .accessibilityLabel("Aumentar a fonte")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}
