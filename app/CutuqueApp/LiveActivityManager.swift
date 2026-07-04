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
/// Chave do toggle "Live Activity ligada" (default: ligada).
enum LiveActivityKeys {
    static let enabled = "cutuque.liveActivityEnabled"
    static func isEnabled() -> Bool {
        // Ausente = ligada por padrão.
        UserDefaults.standard.object(forKey: enabled) == nil
            ? true : UserDefaults.standard.bool(forKey: enabled)
    }
}

@available(iOS 16.1, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<CutuqueActivityAttributes>?
    private let api = APIClient()
    private init() {}

    /// Encerra a Live Activity ativa (e quaisquer órfãs) na hora — usado pelo
    /// toggle "desligar" nos ajustes.
    func endActive() {
        activity = nil
        for a in Activity<CutuqueActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// live = sessões ao vivo (panes de tmux); active = quantas rodando agora.
    func update(live: Int, active: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Desligada nos ajustes: encerra e não cria mais.
        guard LiveActivityKeys.isEnabled() else { endActive(); return }
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
                // pushType .token: a activity ganha um push token; registramos ele
                // no hub (platform "liveactivity") pra o hub atualizar os contadores
                // com o app FECHADO (push-to-activity).
                let act = try Activity.request(
                    attributes: CutuqueActivityAttributes(),
                    content: ActivityContent(state: content, staleDate: nil),
                    pushType: .token)
                activity = act
                observePushToken(act)
            } catch {
                print("[LiveActivity] falha ao iniciar: \(error.localizedDescription)")
            }
        }
    }

    /// Observa o push token da activity e o registra no hub (best-effort).
    private func observePushToken(_ act: Activity<CutuqueActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in act.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                try? await self?.api.registerDevice(token: hex, platform: "liveactivity")
            }
        }
    }
}
