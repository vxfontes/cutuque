import SwiftUI

/// Apelidos de sessão definidos pela usuária — SÓ no app (UserDefaults). Não
/// afetam a sessão real no hub: é puramente cosmético/local. Quando existe um
/// apelido, ele substitui o título original na lista e no detalhe.
@MainActor
final class SessionNamesStore: ObservableObject {
    static let shared = SessionNamesStore()

    private let key = "session_custom_names"
    @Published private var names: [String: String]

    private init() {
        names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Apelido da sessão, se houver (nil quando não renomeada ou apelido vazio).
    func customName(for id: String) -> String? {
        guard let n = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else {
            return nil
        }
        return n
    }

    /// Título a exibir: o apelido local, ou o título original da sessão.
    func displayTitle(for session: Session) -> String {
        customName(for: session.id) ?? session.title
    }

    /// Define (ou limpa, se vazio) o apelido de uma sessão e persiste.
    func setName(_ name: String, for id: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: id)
        } else {
            names[id] = trimmed
        }
        UserDefaults.standard.set(names, forKey: key)
    }
}

/// Ícone da máquina onde a sessão roda (indicador de "onde está rodando").
func machineSymbol(_ machine: String) -> String {
    switch machine.lowercased() {
    case let m where m.contains("macbook"): return "laptopcomputer"
    case let m where m.contains("macmini"): return "macmini"
    case let m where m.contains("win"), let m where m.contains("desktop"): return "pc"
    case let m where m.contains("zima"), let m where m.contains("server"): return "server.rack"
    default: return "desktopcomputer"
    }
}
