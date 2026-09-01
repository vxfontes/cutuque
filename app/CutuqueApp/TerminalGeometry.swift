import CoreGraphics

/// Geometria do espelho de terminal. Só função pura — sem SwiftUI, sem rede —
/// para caber em teste.
///
/// **Nada aqui estima o tamanho do texto.** A versão anterior calculava
/// `cols`/`rows` a partir de duas razões fixas (0.62 de largura, 1.28 de
/// altura) e de uma "altura de cromo" de 120 pt. A da largura estava certa; a
/// da altura custava linha, e o cromo era chute.
///
/// O que a medição mostrou (`ImageRenderer` no simulador de iPad, iOS 26,
/// `.system(size:design:.monospaced)`, corpos de 5 a 22 pt):
///
/// - **largura**: 0.6182–0.6190 × corpo, praticamente constante. O 0.62 antigo
///   acertava (com uma folga de 0.2%).
/// - **altura de linha**: um INTEIRO que sobe em degraus irregulares — 5 pt→6,
///   10 pt→12, 11 pt→14, 13 pt→16, 15 pt→18, 16 pt→20, 21 pt→26. Em razão do
///   corpo isso oscila entre 1.20 e 1.3333 sem monotonia, então nenhuma
///   constante única serve. O 1.28 antigo ficava ACIMA do valor real em 17 dos
///   18 tamanhos: nos 13 pt padrão do iPad pedia 16.64 onde a linha mede 16
///   (~4% menos linhas do que cabem) e nos 10 pt do iPhone pedia 12.8 onde
///   mede 12 (~6.7% menos).
///
/// Nem a métrica do CoreText serve de atalho: `ceil(ascent+descent+leading)`
/// erra ±1 em vários tamanhos, e `defaultLineHeight` também. E os números do
/// macOS são OUTROS (10 pt→13 lá, 12 aqui) — medir na plataforma errada teria
/// só trocado o chute de lugar.
///
/// A saída é não modelar: a view mede uma linha de verdade com a mesma fonte
/// (a "régua", ver `TextMetrics` e `TerminalMirrorView`) e passa o resultado
/// aqui. As únicas constantes que sobraram são o padding que a própria view
/// aplica ao texto — os mesmos literais, lidos deste enum pelos dois lados,
/// então não há como um mudar sem o outro.
enum TerminalGeometry {
    /// Padding que `TerminalMirrorView` aplica ao texto do terminal, por lado.
    /// A view lê estes valores no `.padding(...)`; a conta abaixo desconta o
    /// dobro (os dois lados). Fonte única de propósito: quando eram literais
    /// separados, o `16`/`120` daqui e o `.padding(8/10)` de lá podiam
    /// divergir em silêncio.
    static let horizontalTextPadding: CGFloat = 8
    static let verticalTextPadding: CGFloat = 10

    static let minColumns = 30
    static let minRows = 20

    static let fontMin: Double = 5
    static let fontMax: Double = 22

    /// Tamanho de UM caractere e de UMA linha, medidos pelo próprio SwiftUI —
    /// ver `TerminalMirrorView.ruler`. `charWidth` vem de uma amostra de
    /// `sampleLength` caracteres dividida pelo comprimento, porque o SwiftUI
    /// arredonda a largura da LINHA pra cima (uma amostra de 1 caractere
    /// herdaria o arredondamento inteiro e engordaria a conta em até 1 pt por
    /// coluna).
    struct TextMetrics: Equatable {
        var charWidth: CGFloat
        var lineHeight: CGFloat

        /// Válida só com as duas dimensões positivas — antes da primeira
        /// medição a régua reporta `.zero`, e dividir por zero aqui daria
        /// `inf` (que `Int(...)` transforma em crash, não em número grande).
        var isUsable: Bool { charWidth > 0 && lineHeight > 0 }

        /// Converte o tamanho medido da régua (`sampleLength` caracteres numa
        /// linha só) em métricas por caractere. `nil` quando a medida ainda
        /// não vale nada — é o mesmo guard do `isUsable`, só que na entrada,
        /// pra `TerminalMirrorView` nunca guardar uma métrica inútil no
        /// `@State`.
        init?(sampleSize: CGSize) {
            guard sampleSize.width > 0, sampleSize.height > 0 else { return nil }
            self.charWidth = sampleSize.width / CGFloat(TerminalGeometry.sampleLength)
            self.lineHeight = sampleSize.height
        }

        init(charWidth: CGFloat, lineHeight: CGFloat) {
            self.charWidth = charWidth
            self.lineHeight = lineHeight
        }
    }

    /// Quantos caracteres a régua renderiza pra medir a largura média.
    static let sampleLength = 100

    /// Colunas que cabem na largura ÚTIL do terminal (a largura do viewport
    /// menos o padding do texto).
    static func columns(width: CGFloat, metrics: TextMetrics) -> Int {
        guard metrics.isUsable else { return minColumns }
        let usable = width - horizontalTextPadding * 2
        return max(minColumns, Int(usable / metrics.charWidth))
    }

    /// Linhas que cabem na altura ÚTIL do terminal.
    ///
    /// `height` é a altura do VIEWPORT do terminal (a `ScrollView`), medida —
    /// não a altura do painel inteiro menos um chute pras barras de teclas e
    /// de input. É por isso que não existe mais `verticalChrome`: as barras
    /// simplesmente não estão dentro do que se mede.
    static func rows(height: CGFloat, metrics: TextMetrics) -> Int {
        guard metrics.isUsable else { return minRows }
        let usable = height - verticalTextPadding * 2
        return max(minRows, Int(usable / metrics.lineHeight))
    }

    /// Quantas vezes a janela do tmux é mais alta que a tela do aparelho.
    ///
    /// [01/09/2026] _"aumente a quantidade de linhas iniciais que vem"_. A
    /// primeira tentativa foi subir o `tmuxScrollback` do hub de 500 para 2000,
    /// e ela não entrega LINHA NENHUMA: o pane do agente roda em tela
    /// alternada (`alternate_on=1`, `history_size=0` — medido em `claude`,
    /// `codex` e `opencode`), e nesse modo o tmux não acumula histórico. Vale
    /// para os três agentes, então `capture-pane -S -N` devolve byte a byte a
    /// mesma coisa para qualquer `N`.
    ///
    /// O que sobra de alavanca é esta: em tela alternada a captura devolve
    /// exatamente A JANELA, e quem define a janela é o app (`model.resize`,
    /// `resize-window -y`). Pedir uma janela mais alta que a tela faz a TUI
    /// redesenhar o transcript preenchendo a altura nova — aí a linha a mais
    /// EXISTE, e a `ScrollView` do espelho rola dentro dela.
    ///
    /// O custo é o poll: a tela inteira é recapturada a cada 500 ms enquanto se
    /// mexe (`PollPacer.piso`), então a janela mais alta é trafegada duas vezes
    /// por segundo. Medido numa tela real de 69 linhas (`capture-pane -e -p |
    /// wc -c` = 7530 bytes) dá ~109 bytes por linha com ANSI: as ~50 linhas de
    /// hoje no iPhone custam ~5,5 KB por captura, e com fator 3 vão a ~16 KB.
    /// É a mesma conta que manteve o `tmuxScrollback` em 500 — a diferença é
    /// que lá o byte a mais comprava zero linha e aqui compra três.
    static let fatorDeContexto = 3

    /// Teto absoluto de linhas pedidas ao tmux, independente do fator.
    ///
    /// Sem ele o iPad em tela cheia (~70 linhas) pediria 210, e a conta de
    /// banda acima deixa de fechar. O piso (`minRows`) protege a outra ponta.
    static let maxRows = 200

    /// Linhas PEDIDAS ao tmux — o que vai no `resize-window -y`.
    ///
    /// Não confundir com `rows(height:metrics:)`, que continua sendo "o que
    /// cabe na tela". As duas são propositalmente diferentes: a janela é maior
    /// que o viewport, e é essa diferença que vira contexto rolável.
    static func rowsPedidas(height: CGFloat, metrics: TextMetrics) -> Int {
        min(maxRows, rows(height: height, metrics: metrics) * fatorDeContexto)
    }

    /// 10 pt foi calibrado pros 393 pt do iPhone; num painel de detalhe de iPad
    /// isso vira letra miúda demais pra ler de braço estendido.
    static func defaultFontPt(isPad: Bool) -> Double { isPad ? 13 : 10 }
}

// Aqui morava `enum PadLayout`, com o limiar de 700 pt que decidia o colapso da
// split view do iPad ("regra dos 700 pt"). Essa regra foi substituída por
// orientação (`NavigationState.applyLayoutRule`) e o enum ficou com um único
// membro, usado por um único consumidor num assunto diferente — a paginação de
// colunas do kanban. O limiar foi pra junto desse consumidor, como
// `BoardLayout.columnPagingThreshold` (`BoardMoveLogic.swift`). Não há mais
// nenhuma constante de largura compartilhada entre board e terminal: os dois
// números são independentes e podem divergir sem se afetarem.
