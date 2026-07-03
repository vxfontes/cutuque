import SwiftUI

@main
struct CutuqueApp: App {
    // Liga o AppDelegate (device token + delegate de notificações) ao ciclo de vida.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Router de deep-link compartilhado (mesma instância usada pelo PushManager).
    @StateObject private var router = Router.shared
    // Aparência (modo claro/escuro) + tema de cor, aplicados na raiz. @AppStorage
    // observa as chaves — mudou nos ajustes, re-aplica aqui na hora.
    @AppStorage(AppThemeKeys.colorScheme) private var colorSchemeRaw = AppColorScheme.system.rawValue
    @AppStorage(AppThemeKeys.accent) private var accentRaw = AppAccent.blue.rawValue
    // Fase da cena: informa o hub foreground/background (suprime push com o app aberto).
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // Lista de sessões é a tela raiz (ela própria hospeda a NavigationStack).
            SessionListView()
            .environmentObject(router)
            .tint((AppAccent(rawValue: accentRaw) ?? .blue).color)
            .preferredColorScheme((AppColorScheme(rawValue: colorSchemeRaw) ?? .system).scheme)
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
