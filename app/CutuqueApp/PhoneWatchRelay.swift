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
                    // Perguntas de seleção (AskUserQuestion), se houver — o relógio
                    // usa isso pra desenhar as opções em vez do sim/não.
                    let questions = (s.pendingQuestions ?? []).map { q -> [String: Any] in
                        [
                            "question": q.question,
                            "header": q.header,
                            "multiSelect": q.multiSelect,
                            "options": q.options.map { opt -> [String: Any] in
                                ["label": opt.label, "description": opt.description ?? ""]
                            },
                        ]
                    }
                    return [
                        "id": s.id,
                        "title": s.title,
                        "prompt": (s.pendingPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        "hasPane": s.tmuxTarget != nil,
                        // Sessão externa (hook/tmux de terceiro): o hub NÃO controla o
                        // gate dela, então o relógio a trata como read-only (não
                        // oferece aprovar/negar/responder — a resposta é no terminal).
                        "isExternal": s.isExternal,
                        "questions": questions,
                    ]
                }
                replyHandler(["sessions": needs])
            case "approve":
                replyHandler(["ok": (try? await api.approve(sessionID: id)) != nil])
            case "deny":
                replyHandler(["ok": (try? await api.deny(sessionID: id)) != nil])
            case "reply":
                guard let text = message["text"] as? String, !text.isEmpty else { replyHandler(["ok": false]); return }
                replyHandler(["ok": (try? await api.reply(sessionID: id, text: text)) != nil])
            case "answer":
                // Resposta a pergunta de seleção — vinda do pulso já pronta como
                // [{"question":..., "selected":[...]}]. Pergunta não tem
                // "aprovar": só responde (aqui) ou cancela (deny). Reporta sucesso
                // REAL (não engole erro): senão o pulso dá haptic + dismiss de falso
                // sucesso quando a resposta não chegou ao processo (ex.: 409).
                guard let rawAnswers = message["answers"] as? [[String: Any]] else {
                    replyHandler(["ok": false]); return
                }
                let items = rawAnswers.compactMap { dict -> APIClient.AnswerItem? in
                    guard let question = dict["question"] as? String,
                          let selected = dict["selected"] as? [String], !selected.isEmpty else { return nil }
                    return APIClient.AnswerItem(question: question, selected: selected)
                }
                guard !items.isEmpty else { replyHandler(["ok": false]); return }
                replyHandler(["ok": (try? await api.answer(sessionID: id, answers: items)) != nil])
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
