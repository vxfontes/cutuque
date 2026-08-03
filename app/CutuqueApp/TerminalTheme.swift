import SwiftUI
import SwiftTerm
import UIKit

// MARK: - Catálogo

/// Paleta completa do terminal PTY da aba Máquinas (fundo, texto, cursor e as
/// 16 cores ANSI), escolhida POR MÁQUINA (`machine.theme`).
///
/// Não é o `TerminalTheme` (enum) de `TerminalMirrorView.swift` — aquele é a
/// preferência GLOBAL do espelho do tmux (só bg/fg, sem paleta ANSI), e
/// continua assim de propósito: a usuária pediu tema por máquina aqui, não
/// migração do espelho antigo. Os dois coexistem sem colidir porque têm nomes
/// de tipo diferentes.
///
/// Cor guardada como hex (`String`), não já convertida: a mesma paleta
/// alimenta SwiftUI (preview), `UIColor` (bg/fg/cursor da `TerminalView`) e
/// `SwiftTerm.Color` (as 16 ANSI que `installColors` instala) — três formatos
/// que não convertem entre si de graça, e os conversores prontos da própria
/// SwiftTerm (`UIColor.make(color:)`, `getTerminalColor()`) são `internal` à
/// lib: inacessíveis por quem só depende dela via SPM.
struct TerminalPalette: Identifiable, Hashable {
    /// Slug estável — é a STRING que o hub guarda em `machine.theme` e que o
    /// `TerminalThemePicker` mexe via `Binding<String>`. NUNCA mude o id de um
    /// tema já publicado: a máquina só guarda a string, então trocar o id
    /// aqui não migra nada — só faz `byID` não achar mais o tema e cair no
    /// Padrão.
    let id: String
    /// Rótulo em pt-BR (ou nome próprio do tema, como "Dracula"/"Nord").
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    /// 16 cores ANSI, hex, nesta ordem: preto, vermelho, verde, amarelo,
    /// azul, magenta, ciano, branco — normais (0-7) e depois as versões
    /// brilhantes (8-15). É a ordem que `installColors` da SwiftTerm espera.
    let ansi: [String]
}

// MARK: - Conversão (hex → SwiftUI / UIKit / SwiftTerm)

extension TerminalPalette {
    /// Componentes 0-255 de um hex `"#rrggbb"` (ou `"rrggbb"` sem `#`). `nil`
    /// só em hex malformado — não deveria acontecer com os hex fixos deste
    /// catálogo, mas um crash por causa de cor não vale o risco.
    static func components8(hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    // `Color` sozinho seria ambíguo aqui: este arquivo importa SwiftUI E
    // SwiftTerm, e as duas expõem um tipo `Color` no top level. Qualificado
    // por extenso pra não depender de qual delas o compilador prefere.
    private static func color(hex: String) -> SwiftUI.Color {
        guard let c = components8(hex: hex) else { return .black }
        return SwiftUI.Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    private static func uiColor(hex: String) -> UIColor {
        guard let c = components8(hex: hex) else { return .black }
        return UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// 8 bit → 16 bit por `valor * 257` (255*257 = 65535, sem perda nas
    /// pontas). É a mesma expansão que o inicializador `Color(red8:...)` da
    /// SwiftTerm faz por dentro — só que aquele é `internal` à lib, então a
    /// conta é replicada aqui.
    private static func swiftTermColor(hex: String) -> SwiftTerm.Color {
        guard let c = components8(hex: hex) else { return SwiftTerm.Color(red: 0, green: 0, blue: 0) }
        return SwiftTerm.Color(red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257)
    }

    var backgroundColor: SwiftUI.Color { Self.color(hex: background) }
    var foregroundColor: SwiftUI.Color { Self.color(hex: foreground) }
    var cursorColor: SwiftUI.Color { Self.color(hex: cursor) }

    var nativeBackground: UIColor { Self.uiColor(hex: background) }
    var nativeForeground: UIColor { Self.uiColor(hex: foreground) }
    var nativeCursor: UIColor { Self.uiColor(hex: cursor) }

    /// As 16 cores prontas pro `installColors(_:)` da `TerminalView`.
    var ansiSwiftTermColors: [SwiftTerm.Color] { ansi.map(Self.swiftTermColor(hex:)) }

    /// Uma das 16 ANSI já em `SwiftUI.Color`, pro preview do
    /// `TerminalThemePicker`. Índice fora de 0..<16 cai no texto do tema (não
    /// deveria acontecer, mas um preview não é lugar pra crashar por índice).
    func ansiColor(_ index: Int) -> SwiftUI.Color {
        guard ansi.indices.contains(index) else { return foregroundColor }
        return Self.color(hex: ansi[index])
    }
}

// MARK: - Catálogo oficial

extension TerminalPalette {
    /// id `""` = o de HOJE, antes desta feature existir. Fundo/texto batem
    /// com o que `MachineDetailView` já usava (`TerminalTheme.dark` do enum
    /// antigo: `Color(white: 0.08)`/`Color(white: 0.92)`) e as 16 ANSI são as
    /// `Color.terminalAppColors` da própria SwiftTerm — o padrão que já
    /// aparecia na tela porque `installColors` nunca tinha sido chamado.
    /// Trocar isso mudaria a cara do terminal pra quem nunca pediu tema
    /// nenhum.
    static let padrao = TerminalPalette(
        id: "", name: "Padrão",
        background: "#141414", foreground: "#EBEBEB", cursor: "#EBEBEB",
        ansi: ["#000000", "#C23621", "#25BC24", "#ADAD27",
               "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
               "#818383", "#FC391F", "#31E722", "#EAEC23",
               "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB"]
    )

    /// Fonte de todas as paletas abaixo (menos o Padrão): specs oficiais de
    /// cada projeto, via o port consolidado `mbadolato/iTerm2-Color-Schemes`
    /// (conferido em 03/08/2026, arquivos `.itermcolors` lidos direto —
    /// nenhum valor chutado).
    static let dracula = TerminalPalette(
        id: "dracula", name: "Dracula",
        background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2",
        ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
               "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
               "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
               "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
    )

    static let solarizedDark = TerminalPalette(
        id: "solarizedDark", name: "Solarized Dark",
        background: "#002B36", foreground: "#839496", cursor: "#839496",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900",
               "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
               "#002B36", "#CB4B16", "#586E75", "#657B83",
               "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    )

    /// Mesma tabela ANSI do Solarized Dark — é assim no spec original (as 16
    /// cores são invariantes entre as duas variantes; só bg/fg trocam).
    static let solarizedLight = TerminalPalette(
        id: "solarizedLight", name: "Solarized Light",
        background: "#FDF6E3", foreground: "#657B83", cursor: "#657B83",
        ansi: solarizedDark.ansi
    )

    static let nord = TerminalPalette(
        id: "nord", name: "Nord",
        background: "#2E3440", foreground: "#D8DEE9", cursor: "#ECEFF4",
        ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
               "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
               "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
               "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]
    )

    static let gruvboxDark = TerminalPalette(
        id: "gruvboxDark", name: "Gruvbox Dark",
        background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2",
        ansi: ["#282828", "#CC241D", "#98971A", "#D79921",
               "#458588", "#B16286", "#689D6A", "#A89984",
               "#928374", "#FB4934", "#B8BB26", "#FABD2F",
               "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]
    )

    static let tomorrowNight = TerminalPalette(
        id: "tomorrowNight", name: "Tomorrow Night",
        background: "#1D1F21", foreground: "#C5C8C6", cursor: "#C5C8C6",
        ansi: ["#000000", "#CC6666", "#B5BD68", "#F0C674",
               "#81A2BE", "#B294BB", "#8ABEB7", "#FFFFFF",
               "#000000", "#CC6666", "#B5BD68", "#F0C674",
               "#81A2BE", "#B294BB", "#8ABEB7", "#FFFFFF"]
    )

    /// "One Dark" = a paleta de terminal do Atom (`Atom One Dark`), não a
    /// sintaxe do editor — é a que os ports de terminal padronizaram.
    static let oneDark = TerminalPalette(
        id: "oneDark", name: "One Dark",
        background: "#21252B", foreground: "#ABB2BF", cursor: "#ABB2BF",
        ansi: ["#21252B", "#E06C75", "#98C379", "#E5C07B",
               "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
               "#767676", "#E06C75", "#98C379", "#E5C07B",
               "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF"]
    )

    static let catppuccinMocha = TerminalPalette(
        id: "catppuccinMocha", name: "Catppuccin Mocha",
        background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC",
        ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
               "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
               "#585B70", "#F7AEC2", "#C2ECBF", "#FCD682",
               "#AECCFC", "#F398DA", "#B1EAE1", "#A6ADC8"]
    )

    static let all: [TerminalPalette] = [
        padrao, dracula, solarizedDark, solarizedLight, nord,
        gruvboxDark, tomorrowNight, oneDark, catppuccinMocha,
    ]

    /// Cai no Padrão pra id vazio (nunca escolheu) OU desconhecido (tema
    /// removido do catálogo num futuro update) — nas duas situações o
    /// terminal continua colorido em vez de quebrar.
    static func byID(_ id: String) -> TerminalPalette {
        all.first { $0.id == id } ?? padrao
    }
}
