import Foundation
import WatchConnectivity
import WatchKit

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

    /// Ids de needs_you já vistos: uma sessão NOVA na lista dispara o haptic de
    /// "precisa de você" no pulso. `loadedOnce` evita vibrar na 1ª carga.
    private var knownIDs: Set<String> = []
    private var loadedOnce = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        refresh()
    }

    func refresh() {
        send(["action": "needsYou"]) { [weak self] reply in
            guard let self else { return }
            let raw = reply["sessions"] as? [[String: Any]] ?? []
            let list = raw.map {
                WatchSession(
                    id: $0["id"] as? String ?? "",
                    title: $0["title"] as? String ?? "sessão",
                    prompt: $0["prompt"] as? String ?? "",
                    hasPane: $0["hasPane"] as? Bool ?? false)
            }
            // Haptic de "precisa de você" quando uma sessão NOVA aparece (não na
            // 1ª carga). É o cutucão no pulso — distinto do toque de confirmação.
            let ids = Set(list.map(\.id))
            if self.loadedOnce && !ids.subtracting(self.knownIDs).isEmpty {
                WKInterfaceDevice.current().play(.notification)
            }
            self.knownIDs = ids
            self.loadedOnce = true
            self.sessions = list
        }
    }

    func approve(_ id: String) { act(["action": "approve", "id": id], haptic: .success) }
    func deny(_ id: String) { act(["action": "deny", "id": id], haptic: .directionDown) }
    func reply(_ id: String, _ text: String) { act(["action": "reply", "id": id, "text": text], haptic: .success) }

    /// Ação que muda estado: dispara, dá um toque de confirmação e recarrega.
    private func act(_ msg: [String: Any], haptic: WKHapticType) {
        send(msg) { [weak self] _ in
            WKInterfaceDevice.current().play(haptic)
            self?.refresh()
        }
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
