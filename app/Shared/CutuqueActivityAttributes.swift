import ActivityKit
import Foundation

/// Atributos da Live Activity de uma sessão (compartilhado entre o app, que
/// inicia/atualiza/encerra, e a widget extension, que desenha). Os campos fixos
/// ficam em `CutuqueActivityAttributes`; o que muda ao vivo, em `ContentState`.
struct CutuqueActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Estado atual: "running" | "done" | "error" | "needs_you" | "idle".
        var state: String
        /// Título curto da sessão (nome/pasta).
        var title: String
    }

    var sessionID: String
    var machine: String
    /// Quando a activity começou — para o cronômetro "há Xm" na ilha/tela.
    var startedAt: Date
}
