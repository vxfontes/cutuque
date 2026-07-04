import Foundation
import WatchConnectivity

/// Ponte iPhone→hub para o Apple Watch: o relógio não alcança o hub (Tailscale),
/// então manda pedidos via WatchConnectivity e o iPhone faz o HTTP com a config
/// que já tem. sendMessage acorda o app iOS em background quando preciso.
final class PhoneWatchRelay: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchRelay()
    private let api = APIClient()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let action = message["action"] as? String ?? ""
        let id = message["id"] as? String ?? ""
        Task {
            switch action {
            case "needsYou":
                let all = (try? await api.sessions()) ?? []
                let needs = all.filter { $0.state == .needsYou }.map { s -> [String: Any] in
                    [
                        "id": s.id,
                        "title": s.title,
                        "prompt": (s.pendingPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        "hasPane": s.tmuxTarget != nil,
                    ]
                }
                replyHandler(["sessions": needs])
            case "approve":
                try? await api.approve(sessionID: id)
                replyHandler(["ok": true])
            case "deny":
                try? await api.deny(sessionID: id)
                replyHandler(["ok": true])
            case "reply":
                if let text = message["text"] as? String { try? await api.reply(sessionID: id, text: text) }
                replyHandler(["ok": true])
            default:
                replyHandler(["ok": false])
            }
        }
    }

    // Stubs exigidos no iOS (troca de device/conta): re-ativa a sessão.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}
