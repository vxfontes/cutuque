import SwiftUI

// MARK: - Aparência (modo claro/escuro) + tema de cor (accent)

/// Modo de aparência do app: segue o sistema, ou força claro/escuro.
enum AppColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light:  return "Claro"
        case .dark:   return "Escuro"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// nil = segue o sistema (não força esquema nenhum).
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Tema de cor (accent) do app — como os temas do terminal, mas para o realce da
/// interface (botões, seleções, ícones). Não repinta os fundos (respeita o
/// modo claro/escuro), só o "sotaque" de cor.
enum AppAccent: String, CaseIterable, Identifiable {
    case blue, teal, indigo, purple, pink, orange, green, graphite
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:     return "Azul"
        case .teal:     return "Turquesa"
        case .indigo:   return "Índigo"
        case .purple:   return "Roxo"
        case .pink:     return "Rosa"
        case .orange:   return "Laranja"
        case .green:    return "Verde"
        case .graphite: return "Grafite"
        }
    }

    var color: Color {
        switch self {
        case .blue:     return .blue
        case .teal:     return .teal
        case .indigo:   return .indigo
        case .purple:   return .purple
        case .pink:     return .pink
        case .orange:   return .orange
        case .green:    return .green
        case .graphite: return Color(red: 0.42, green: 0.45, blue: 0.5)
        }
    }
}

// MARK: - A cor de destaque como valor de ambiente

private struct ChaveDaCorDeDestaque: EnvironmentKey {
    /// Igual ao `AppAccent` padrão dos ajustes: quem lê fora do app (preview,
    /// teste de view) recebe o mesmo azul que a usuária vê na instalação nova.
    static let defaultValue: Color = AppAccent.blue.color
}

extension EnvironmentValues {
    /// A cor escolhida em Ajustes → Tema, para quem PINTA com ela.
    ///
    /// [13/08/2026] Existe porque `Color.accentColor` **ignora** `.tint(_:)`:
    /// ele resolve do catálogo de assets (`AccentColor.colorset`, que este app
    /// nem tem) ou do azul do sistema — nunca do `tint` do ambiente. Era a causa
    /// de "mesmo eu trocando a cor, alguns lugares fica com cor padrao": os
    /// controles nativos seguiam o `.tint`, e todo `Color.accentColor` escrito à
    /// mão ficava azul.
    ///
    /// Regra: controle nativo herda `.tint` sozinho e não precisa disto; código
    /// que passa uma `Color` explícita (`foregroundStyle`, `fill`, `stroke`,
    /// borda) lê daqui. Cor com SIGNIFICADO — vermelho de erro, verde de ok,
    /// laranja de aviso, paleta de sintaxe — não é destaque e continua literal.
    var corDeDestaque: Color {
        get { self[ChaveDaCorDeDestaque.self] }
        set { self[ChaveDaCorDeDestaque.self] = newValue }
    }
}

/// Aplica a cor de destaque pelos DOIS caminhos de uma vez: `.tint` (controles
/// nativos) e `\.corDeDestaque` (código que pinta com `Color` explícita).
///
/// É um modifier, e não duas linhas soltas na raiz, para que os dois nunca saiam
/// de sincronia — o sintoma disso é o app com metade da interface na cor nova e
/// metade no azul.
struct CorDeDestaqueDoApp: ViewModifier {
    let cor: Color

    func body(content: Content) -> some View {
        content
            .tint(cor)
            .environment(\.corDeDestaque, cor)
    }
}

// Chaves de @AppStorage compartilhadas entre a raiz do app (aplica) e os ajustes
// (edita). @AppStorage é observado pelas Views automaticamente — mudou no ajuste,
// a raiz re-aplica esquema/tint na hora.
enum AppThemeKeys {
    static let colorScheme = "cutuque.appColorScheme"
    static let accent = "cutuque.appAccent"
}

/// Interruptor mestre "Cutuque ativo" (default: ligado). Desligado = o hub não
/// notifica em nada e o app encerra a Live Activity.
enum AppActiveKeys {
    static let active = "cutuque.active"
    static func isActive() -> Bool {
        UserDefaults.standard.object(forKey: active) == nil
            ? true : UserDefaults.standard.bool(forKey: active)
    }
}
