import Foundation
import WatchConnectivity
import WatchKit

/// Uma sessão que precisa de você, resumida para o pulso.
struct WatchSession: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let hasPane: Bool // true = roda no tmux (só dá pra responder pelo terminal)
    /// Sessão externa (hook/tmux de terceiro): o hub não controla o gate dela, então
    /// o pulso a trata como read-only (sem aprovar/negar/responder).
    let isExternal: Bool
    /// Perguntas de seleção pendentes (AskUserQuestion). Vazio = pedido comum
    /// sim/não (aprovar/negar como antes).
    let questions: [WatchQuestion]
}

/// Uma opção de resposta de uma pergunta de seleção, resumida para o pulso.
struct WatchQuestionOption: Identifiable, Equatable, Hashable {
    let label: String
    let description: String
    var id: String { label }
}

/// Uma pergunta de seleção pendente (única ou múltipla), resumida para o pulso.
struct WatchQuestion: Identifiable, Equatable, Hashable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [WatchQuestionOption]
    var id: String { question }
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
            let list = raw.map { dict -> WatchSession in
                let rawQuestions = dict["questions"] as? [[String: Any]] ?? []
                let questions = rawQuestions.map { qDict -> WatchQuestion in
                    let rawOptions = qDict["options"] as? [[String: Any]] ?? []
                    let options = rawOptions.map { oDict in
                        WatchQuestionOption(
                            label: oDict["label"] as? String ?? "",
                            description: oDict["description"] as? String ?? "")
                    }
                    return WatchQuestion(
                        question: qDict["question"] as? String ?? "",
                        header: qDict["header"] as? String ?? "",
                        multiSelect: qDict["multiSelect"] as? Bool ?? false,
                        options: options)
                }
                return WatchSession(
                    id: dict["id"] as? String ?? "",
                    title: dict["title"] as? String ?? "sessão",
                    prompt: dict["prompt"] as? String ?? "",
                    hasPane: dict["hasPane"] as? Bool ?? false,
                    isExternal: dict["isExternal"] as? Bool ?? false,
                    questions: questions)
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
    /// Responde a uma pergunta de seleção. `answers` já vem pronto como
    /// `[{"question": ..., "selected": [...]}]` (o iPhone só repassa ao hub).
    func answer(_ id: String, _ answers: [[String: Any]]) {
        act(["action": "answer", "id": id, "answers": answers], haptic: .success)
    }

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
