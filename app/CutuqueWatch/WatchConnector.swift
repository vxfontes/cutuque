import Foundation
import WatchConnectivity

/// Uma sessão que precisa de você, resumida para o pulso.
struct WatchSession: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let hasPane: Bool // true = roda no tmux (só dá pra responder pelo terminal)
}

/// Cliente FINO do Watch: não fala com o hub direto (o hub só existe na
/// Tailscale, que o relógio não alcança). Em vez disso, manda pedidos ao iPhone
/// via WatchConnectivity; o iPhone faz o HTTP e responde. Precisa do iPhone por
/// perto/alcançável.
@MainActor
final class WatchConnector: NSObject, ObservableObject {
    @Published var sessions: [WatchSession] = []
    @Published var loading = false
    @Published var reachable = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        refresh()
    }

    func refresh() {
        send(["action": "needsYou"]) { [weak self] reply in
            let raw = reply["sessions"] as? [[String: Any]] ?? []
            self?.sessions = raw.map {
                WatchSession(
                    id: $0["id"] as? String ?? "",
                    title: $0["title"] as? String ?? "sessão",
                    prompt: $0["prompt"] as? String ?? "",
                    hasPane: $0["hasPane"] as? Bool ?? false)
            }
        }
    }

    func approve(_ id: String) { act(["action": "approve", "id": id]) }
    func deny(_ id: String) { act(["action": "deny", "id": id]) }
    func reply(_ id: String, _ text: String) { act(["action": "reply", "id": id, "text": text]) }

    /// Ação que muda estado: dispara e recarrega a lista ao voltar.
    private func act(_ msg: [String: Any]) {
        send(msg) { [weak self] _ in self?.refresh() }
    }

    private func send(_ msg: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else {
            reachable = false
            return
        }
        loading = true
        s.sendMessage(msg, replyHandler: { r in
            Task { @MainActor in self.loading = false; self.reachable = true; reply(r) }
        }, errorHandler: { _ in
            Task { @MainActor in self.loading = false; self.reachable = false }
        })
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if state == .activated { self.refresh() }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachable = session.isReachable }
    }
}
