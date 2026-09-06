import SwiftUI

/// Converte texto de terminal com sequências ANSI (SGR) numa AttributedString
/// colorida — para o espelho mostrar as cores REAIS que o claude usa no TUI.
/// Suporta: reset, negrito, cores 16 (normais/bright), 256 e truecolor (24-bit),
/// fg e bg. Sequências não-SGR (mover cursor, limpar) são descartadas.
enum Ansi {

    /// A tela QUEBRADA EM LINHAS, cada uma já com os atributos que valem nela.
    ///
    /// É o varredor de verdade — `attributed` e `plain` são construídos em cima
    /// deste. Existe porque desenhar a tela como um `AttributedString` só custa
    /// ~quadrático na altura: o iOS re-tipografa o bloco inteiro a cada quadro e,
    /// por fragmento de linha, percorre a lista de trechos toda. Medido na tela
    /// real de 145 linhas: bloco único 172 ms, linha a linha 1,9 ms (93x).
    /// Ver `memory/cutuque/app/App — Travamento do Espelho: a Tipografia
    /// Quadrática do Text Único.md` (card `531eb461b9425a72`).
    ///
    /// O estado de SGR ATRAVESSA a quebra de linha de propósito: uma cor aberta
    /// numa linha continua valendo na seguinte até um reset. Quebrar a tela em
    /// pedaços e varrer cada um do zero pintaria errado toda linha que herda cor
    /// — que no TUI do claude é quase toda linha de bloco.
    ///
    /// Devolve a mesma contagem que `components(separatedBy: "\n")`: texto sem
    /// `\n` dá uma linha, e um `\n` final dá uma linha vazia no fim.
    static func attributedLines(_ input: String, size: CGFloat, defaultColor: Color) -> [AttributedString] {
        let baseFont = Font.system(size: size, design: .monospaced)
        var linhas: [AttributedString] = []
        var atual = AttributedString()
        var fg: Color?
        var bg: Color?
        var bold = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            run.font = bold ? baseFont.bold() : baseFont
            run.foregroundColor = fg ?? defaultColor
            if let bg { run.backgroundColor = bg }
            atual += run
            buffer = ""
        }

        func quebrar() {
            flush()
            linhas.append(atual)
            atual = AttributedString()
        }

        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}" {
                flush()
                if i + 1 < scalars.count && scalars[i + 1] == "[" {
                    // CSI: lê params até o byte final (0x40–0x7E).
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) {
                        params.unicodeScalars.append(scalars[j]); j += 1
                    }
                    let final = j < scalars.count ? scalars[j] : Unicode.Scalar("m")
                    if final == "m" { applySGR(params, &fg, &bg, &bold) }
                    i = j + 1
                } else {
                    i += 2 // outra sequência ESC: pula ESC + próximo
                }
                continue
            }
            if c == "\n" {
                quebrar()
                i += 1
                continue
            }
            buffer.unicodeScalars.append(c)
            i += 1
        }
        quebrar()
        return linhas
    }

    /// A tela inteira num `AttributedString` só. Continua existindo para quem
    /// precisa do texto como um bloco (`plain`, e daí a área de transferência);
    /// **não** é o que o espelho desenha — ver `attributedLines`.
    ///
    /// A quebra de linha entra sem atributo nenhum (o `\n` não tem tinta), o que
    /// é a única diferença observável em relação ao varredor de antes.
    static func attributed(_ input: String, size: CGFloat, defaultColor: Color) -> AttributedString {
        var result = AttributedString()
        for (i, linha) in attributedLines(input, size: size, defaultColor: defaultColor).enumerated() {
            if i > 0 { result += AttributedString("\n") }
            result += linha
        }
        return result
    }

    /// O mesmo texto que `attributed` mostraria, sem os atributos — para SAIR do
    /// app (área de transferência, e daí WhatsApp).
    ///
    /// Construída EM CIMA de `attributed` de propósito, não com um segundo
    /// varredor de ANSI: dois varredores divergem com o tempo, e este aqui já é
    /// o que a usuária vê na tela todo dia. `size` e `defaultColor` são
    /// irrelevantes (os atributos são descartados na saída), daí valores fixos.
    static func plain(_ input: String) -> String {
        String(attributed(input, size: 12, defaultColor: .primary).characters)
    }

    private static func applySGR(_ params: String, _ fg: inout Color?, _ bg: inout Color?, _ bold: inout Bool) {
        let tokens = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if tokens.isEmpty { fg = nil; bg = nil; bold = false; return } // ESC[m = reset
        var k = 0
        while k < tokens.count {
            switch tokens[k] {
            case 0:        fg = nil; bg = nil; bold = false
            case 1:        bold = true
            case 22:       bold = false
            case 30...37:  fg = ansi16(tokens[k] - 30, bright: false)
            case 90...97:  fg = ansi16(tokens[k] - 90, bright: true)
            case 39:       fg = nil
            case 40...47:  bg = ansi16(tokens[k] - 40, bright: false)
            case 100...107: bg = ansi16(tokens[k] - 100, bright: true)
            case 49:       bg = nil
            case 38, 48:
                let isFg = tokens[k] == 38
                if k + 1 < tokens.count, tokens[k + 1] == 5, k + 2 < tokens.count {
                    let col = xterm256(tokens[k + 2]); if isFg { fg = col } else { bg = col }; k += 2
                } else if k + 1 < tokens.count, tokens[k + 1] == 2, k + 4 < tokens.count {
                    let col = Color(.sRGB, red: Double(tokens[k + 2]) / 255, green: Double(tokens[k + 3]) / 255, blue: Double(tokens[k + 4]) / 255)
                    if isFg { fg = col } else { bg = col }; k += 4
                }
            default: break
            }
            k += 1
        }
    }

    private static func ansi16(_ n: Int, bright: Bool) -> Color {
        let normal: [Color] = [
            Color(white: 0.10),
            Color(.sRGB, red: 0.80, green: 0.24, blue: 0.24),
            Color(.sRGB, red: 0.30, green: 0.74, blue: 0.36),
            Color(.sRGB, red: 0.83, green: 0.68, blue: 0.28),
            Color(.sRGB, red: 0.34, green: 0.55, blue: 0.94),
            Color(.sRGB, red: 0.74, green: 0.42, blue: 0.84),
            Color(.sRGB, red: 0.27, green: 0.73, blue: 0.78),
            Color(white: 0.78),
        ]
        let brightC: [Color] = [
            Color(white: 0.45),
            Color(.sRGB, red: 1.0, green: 0.42, blue: 0.42),
            Color(.sRGB, red: 0.46, green: 0.94, blue: 0.52),
            Color(.sRGB, red: 1.0, green: 0.84, blue: 0.42),
            Color(.sRGB, red: 0.48, green: 0.70, blue: 1.0),
            Color(.sRGB, red: 0.90, green: 0.56, blue: 1.0),
            Color(.sRGB, red: 0.42, green: 0.90, blue: 0.95),
            Color(white: 1.0),
        ]
        let idx = max(0, min(7, n))
        return bright ? brightC[idx] : normal[idx]
    }

    private static func xterm256(_ n: Int) -> Color {
        if n < 16 { return ansi16(n % 8, bright: n >= 8) }
        if n >= 232 { return Color(white: Double(8 + (n - 232) * 10) / 255) }
        let c = n - 16
        func lvl(_ x: Int) -> Double { x == 0 ? 0 : Double(55 + x * 40) / 255 }
        return Color(.sRGB, red: lvl((c / 36) % 6), green: lvl((c / 6) % 6), blue: lvl(c % 6))
    }
}
