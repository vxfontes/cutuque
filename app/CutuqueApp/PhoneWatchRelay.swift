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
                // Nada de `try?` aqui: se o iPhone não alcançou o hub, o relógio
                // PRECISA saber. Engolir o erro e responder lista vazia fazia o
                // pulso escrever "Tudo em dia" com o hub cheio de pedidos parados.
                do {
                    let all = try await api.sessions()
                    replyHandler(Self.needsYouReply(from: all).wire)
                } catch {
                    replyHandler([WatchWireKey.error: "o iPhone não alcançou o hub"])
                }
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

    /// Traduz a lista completa do hub no que cabe no pulso: as sessões que
    /// precisam de você + a contagem das outras.
    ///
    /// A contagem existe pra tela vazia não ser ambígua. "Tudo em dia" sozinho
    /// tanto pode significar "os seus três agentes estão trabalhando" quanto
    /// "não há agente nenhum" — no pulso, essa diferença é a informação toda.
    static func needsYouReply(from all: [Session]) -> WatchNeedsYouReply {
        var overview = WatchOverview()
        var needs: [WatchSession] = []

        for s in all {
            switch s.state {
            case .needsYou:
                // Perguntas de seleção (AskUserQuestion), se houver — o relógio
                // usa isso pra desenhar as opções em vez do sim/não.
                let questions = (s.pendingQuestions ?? []).map { q in
                    WatchQuestion(question: q.question,
                                  header: q.header,
                                  multiSelect: q.multiSelect,
                                  options: q.options.map {
                                      WatchQuestionOption(label: $0.label, description: $0.description ?? "")
                                  })
                }
                needs.append(WatchSession(
                    id: s.id,
                    title: s.title,
                    machine: s.machine,
                    agent: s.agent,
                    prompt: (s.pendingPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    hasPane: s.tmuxTarget != nil,
                    // Sessão externa (hook/tmux de terceiro): o hub NÃO controla o
                    // gate dela, então o relógio a trata como read-only (não
                    // oferece aprovar/negar/responder — a resposta é no terminal).
                    isExternal: s.isExternal,
                    questions: questions))
            case .running: overview.running += 1
            case .done:    overview.done += 1
            case .error:   overview.error += 1
            case .idle:    overview.idle += 1
            }
        }
        return WatchNeedsYouReply(sessions: needs, overview: overview)
    }

    // Stubs exigidos no iOS (troca de device/conta): re-ativa a sessão.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}
