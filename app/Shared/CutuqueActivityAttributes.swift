import ActivityKit
import Foundation

/// Atributos da Live Activity AGREGADA do Cutuque (uma só, não uma por sessão):
/// mostra, num relance, quantas sessões estão ao vivo no Mac e quantas rodando.
/// Compartilhado entre o app (inicia/atualiza/encerra) e a widget extension (desenha).
struct CutuqueActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Sessões ao vivo no Mac (panes de tmux) — não conta subagentes.
        var live: Int
        /// Quantas dessas estão trabalhando agora (rodando).
        var active: Int
    }

    var name: String = "cutuque"
}
