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

// Chaves de @AppStorage compartilhadas entre a raiz do app (aplica) e os ajustes
// (edita). @AppStorage é observado pelas Views automaticamente — mudou no ajuste,
// a raiz re-aplica esquema/tint na hora.
enum AppThemeKeys {
    static let colorScheme = "cutuque.appColorScheme"
    static let accent = "cutuque.appAccent"
}
