import CoreGraphics

/// Geometria do espelho de terminal. Só função pura — sem SwiftUI, sem rede —
/// para caber em teste. As constantes vêm da conta que já rodava inline na
/// `TerminalMirrorView`: 0.62 é a razão largura/altura do SF Mono com folga pra
/// a linha do claude não re-quebrar; 1.28 é a altura de linha; os 16/120 são o
/// padding horizontal e a altura das barras (teclas + input).
enum TerminalGeometry {
    static let charWidthRatio: CGFloat = 0.62
    static let lineHeightRatio: CGFloat = 1.28
    static let horizontalChrome: CGFloat = 16
    static let verticalChrome: CGFloat = 120

    static let minColumns = 30
    static let minRows = 20

    static let fontMin: Double = 5
    static let fontMax: Double = 22

    static func columns(width: CGFloat, fontPt: CGFloat) -> Int {
        max(minColumns, Int((width - horizontalChrome) / (fontPt * charWidthRatio)))
    }

    static func rows(height: CGFloat, fontPt: CGFloat) -> Int {
        max(minRows, Int((height - verticalChrome) / (fontPt * lineHeightRatio)))
    }

    /// 10 pt foi calibrado pros 393 pt do iPhone; num painel de detalhe de iPad
    /// isso vira letra miúda demais pra ler de braço estendido.
    static func defaultFontPt(isPad: Bool) -> Double { isPad ? 13 : 10 }
}

/// Regras de largura da versão iPad, comuns a board e terminal.
enum PadLayout {
    /// Abaixo disto o painel de detalhe é estreito demais pras duas superfícies
    /// largas: o board fica com coluna de ~110 pt e o terminal cai abaixo das
    /// 80 colunas clássicas. Nesses casos o destino abre já expandido.
    static let expandThreshold: CGFloat = 700

    static func startsExpanded(detailWidth: CGFloat) -> Bool {
        detailWidth > 0 && detailWidth < expandThreshold
    }
}
