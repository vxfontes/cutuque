import SwiftUI
import UIKit

/// Avisa o hub quando o app está aberto (foreground), com heartbeat periódico,
/// para o hub suprimir push enquanto isso — quando o app está aberto a usuária
/// já vê tudo ao vivo pelo WS, não precisa ser cutucada.
///
/// Ao ir pro background manda `active:false` na hora; enquanto foreground manda
/// `true` a cada `heartbeat` (o hub tem um TTL maior que isso, então se o app
/// morrer o push volta sozinho).
@MainActor
final class ForegroundReporter: ObservableObject {
    static let shared = ForegroundReporter()

    private let api = APIClient()
    private var task: Task<Void, Never>?
    /// Menor que o TTL do hub (150s) para nunca deixar a supressão expirar
    /// enquanto o app está de fato aberto.
    private let heartbeat: Duration = .seconds(60)

    private init() {}

    /// Reage a uma mudança de fase da cena.
    func update(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Re-registra o device (recupera de um restart do hub, que apaga os
            // devices em memória) e começa o heartbeat de foreground.
            PushManager.shared.refreshRegistration()
            // Reafirma o interruptor mestre (o `muted` do hub é em memória; um
            // restart do hub o perderia — reasserta o estado atual).
            Task { await api.setActive(AppActiveKeys.isActive()) }
            startHeartbeat()
        case .background, .inactive:
            stopHeartbeat()
        @unknown default:
            stopHeartbeat()
        }
    }

    /// Relógio monotônico do cliente em ms (systemUptime não anda pra trás com
    /// ajuste de relógio; cresce entre launches até um reboot). Ordena os
    /// updates de foreground no hub (SEC-102).
    private func nowMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    private func startHeartbeat() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.api.setForeground(true, at: self.nowMs())
                try? await Task.sleep(for: self.heartbeat)
            }
        }
    }

    private func stopHeartbeat() {
        task?.cancel()
        task = nil
        // Avisa o hub na hora que saiu (não espera o TTL expirar). `at` maior que
        // o último heartbeat garante que este `false` vença um `true` atrasado.
        // beginBackgroundTask: o POST completa mesmo com o app indo pra suspensão
        // (senão a supressão poderia "grudar" até o TTL — push perdido ao fechar).
        let at = nowMs()
        let app = UIApplication.shared
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = app.beginBackgroundTask(withName: "cutuque.foreground.off") {
            app.endBackgroundTask(bg); bg = .invalid
        }
        Task {
            await api.setForeground(false, at: at)
            if bg != .invalid { app.endBackgroundTask(bg) }
        }
    }
}
