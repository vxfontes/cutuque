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

// Aqui morava `enum PadLayout`, com o limiar de 700 pt que decidia o colapso da
// split view do iPad ("regra dos 700 pt"). Essa regra foi substituída por
// orientação (`NavigationState.applyLayoutRule`) e o enum ficou com um único
// membro, usado por um único consumidor num assunto diferente — a paginação de
// colunas do kanban. O limiar foi pra junto desse consumidor, como
// `BoardLayout.columnPagingThreshold` (`BoardMoveLogic.swift`). Não há mais
// nenhuma constante de largura compartilhada entre board e terminal: os dois
// números são independentes e podem divergir sem se afetarem.
