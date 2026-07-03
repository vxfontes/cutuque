import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Mantém as Live Activities (tela de bloqueio + Dynamic Island) em sincronia com
/// as sessões que estão RODANDO: inicia uma quando uma sessão entra em running,
/// atualiza o estado, e encerra (mostrando "concluiu") quando ela sai de running.
///
/// Dirigido pelo app enquanto ele está vivo (o WS alimenta `sessions`). Atualização
/// com o app totalmente fechado exigiria push para a activity (dívida futura); a
/// activity persiste na tela de bloqueio com o último estado até lá.
@available(iOS 16.1, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activities: [String: Activity<CutuqueActivityAttributes>] = [:]
    /// Teto de activities simultâneas (o sistema também limita).
    private let maxActivities = 3
    private init() {}

    func sync(sessions: [Session]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let running = sessions.filter { $0.state == .running }
        let runningIDs = Set(running.map(\.id))

        // Encerra as activities cujas sessões não estão mais rodando (mostra o
        // estado final por alguns segundos antes de sumir).
        for (id, act) in activities where !runningIDs.contains(id) {
            let s = sessions.first { $0.id == id }
            let finalState = s?.state.wireValue ?? "done"
            let title = s?.title ?? act.attributes.sessionID
            let content = CutuqueActivityAttributes.ContentState(state: finalState, title: title)
            Task {
                await act.end(ActivityContent(state: content, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(5)))
            }
            activities.removeValue(forKey: id)
        }

        // Inicia/atualiza para as sessões rodando (até o teto).
        for s in running.prefix(maxActivities) {
            let content = CutuqueActivityAttributes.ContentState(state: s.state.wireValue, title: s.title)
            if let act = activities[s.id] {
                Task { await act.update(ActivityContent(state: content, staleDate: nil)) }
            } else {
                do {
                    let attr = CutuqueActivityAttributes(sessionID: s.id, machine: s.machine, startedAt: Date())
                    let act = try Activity.request(
                        attributes: attr,
                        content: ActivityContent(state: content, staleDate: nil))
                    activities[s.id] = act
                } catch {
                    print("[LiveActivity] falha ao iniciar: \(error.localizedDescription)")
                }
            }
        }
    }
}
