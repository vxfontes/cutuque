import SwiftUI

@main
struct CutuqueApp: App {
    // Liga o AppDelegate (device token + delegate de notificações) ao ciclo de vida.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Router de deep-link compartilhado (mesma instância usada pelo PushManager).
    @StateObject private var router = Router.shared
    // Fase da cena: informa o hub foreground/background (suprime push com o app aberto).
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // Lista de sessões é a tela raiz (ela própria hospeda a NavigationStack).
            SessionListView()
            .environmentObject(router)
            .task {
                // Não bloquear a UI no launch: pede autorização após ~1s.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await PushManager.shared.requestAuthorization()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            ForegroundReporter.shared.update(phase)
        }
    }
}
