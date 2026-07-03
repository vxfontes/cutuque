import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Mantém UMA Live Activity agregada (Dynamic Island / tela de bloqueio) com o
/// resumo das sessões ao vivo no Mac: total ao vivo e quantas rodando. Inicia
/// quando há ao menos uma ao vivo, atualiza os números, e encerra quando zera.
///
/// Dirigido pelo app enquanto vivo (o poll de /tmux alimenta os números).
/// Atualização com o app fechado exigiria push-to-activity (dívida futura).
@available(iOS 16.1, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<CutuqueActivityAttributes>?
    private init() {}

    /// live = sessões ao vivo (panes de tmux); active = quantas rodando agora.
    func update(live: Int, active: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Reassume uma activity já existente (ex.: app reaberto) para não duplicar.
        if activity == nil {
            activity = Activity<CutuqueActivityAttributes>.activities.first
        }
        let content = CutuqueActivityAttributes.ContentState(live: live, active: active)

        if live <= 0 {
            if let a = activity {
                Task { await a.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .immediate) }
                activity = nil
            }
            return
        }
        if let a = activity {
            Task { await a.update(ActivityContent(state: content, staleDate: nil)) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: CutuqueActivityAttributes(),
                    content: ActivityContent(state: content, staleDate: nil))
            } catch {
                print("[LiveActivity] falha ao iniciar: \(error.localizedDescription)")
            }
        }
    }
}
