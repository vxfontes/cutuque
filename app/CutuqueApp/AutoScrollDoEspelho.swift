import CoreGraphics

/// Decide se o espelho pode puxar a tela pro fim sozinho.
///
/// [01/09/2026] Nasceu junto com a janela de contexto (`TerminalGeometry
/// .fatorDeContexto`), e não é enfeite dela: é o que a torna utilizável.
///
/// Enquanto a janela do tmux tinha exatamente a altura do viewport, a
/// `ScrollView` do espelho não tinha nada pra rolar, e o `.onChange(of:
/// model.screen)` que pula pro fim a cada quadro era inofensivo. Com a janela
/// três vezes mais alta, o mesmo pulo passa a arrancar a leitura de volta pro
/// fim a cada captura — até duas vezes por segundo, no piso do `PollPacer`. O
/// contexto a mais chegaria e seria ilegível.
///
/// Tipo puro (sem SwiftUI) de propósito, pelo mesmo motivo de
/// `TerminalGeometry` e `SonoRestante`: a regra cabe em teste, a view não.
struct PortaoDeAutoScroll: Equatable {
    /// Ligado = o espelho segue o fim sozinho. É o estado inicial: abrir o
    /// espelho é querer ver o que está acontecendo AGORA.
    private(set) var presoAoFim = true

    /// O quadro que acabou de chegar pode rolar a tela?
    var deveSeguirOFim: Bool { presoAoFim }

    /// A pílula "ao vivo" só existe enquanto a leitura está parada no meio —
    /// solta, ela não teria o que fazer.
    var mostraVoltarAoVivo: Bool { !presoAoFim }

    /// Arrastar o dedo pela tela solta o portão.
    ///
    /// Só arrasto VERTICAL conta. Um gesto horizontal no espelho é seleção de
    /// texto (`.textSelection(.enabled)`) ou toque que escorregou, e desligar
    /// o "ao vivo" ali seria desligar por engano — o pior tipo de estado
    /// grudento, porque a usuária não vê o que fez.
    ///
    /// Translação zerada não é arrasto: `abs(0) > abs(0)` é falso, então um
    /// toque parado que o `DragGesture` reporte não solta nada.
    mutating func arrastou(translation: CGSize) {
        if Self.ehVertical(translation) { presoAoFim = false }
    }

    /// Volta a seguir o fim — pela pílula, ou quando o espelho (re)abre.
    mutating func voltarAoVivo() {
        presoAoFim = true
    }

    static func ehVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width)
    }
}
