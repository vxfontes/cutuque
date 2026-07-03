import SwiftUI

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
            startHeartbeat()
        case .background, .inactive:
            stopHeartbeat()
        @unknown default:
            stopHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.api.setForeground(true)
                try? await Task.sleep(for: self.heartbeat)
            }
        }
    }

    private func stopHeartbeat() {
        task?.cancel()
        task = nil
        // Avisa o hub na hora que saiu (não espera o TTL expirar).
        Task { await api.setForeground(false) }
    }
}
