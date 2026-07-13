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
            // Raiz = TabView com bottom bar (Sessões / Board).
            RootTabView()
            .environmentObject(router)
            .tint((AppAccent(rawValue: accentRaw) ?? .blue).color)
            .preferredColorScheme((AppColorScheme(rawValue: colorSchemeRaw) ?? .system).scheme)
            // Deep-link da Live Activity: cutuque://session/<id> abre a sessão.
            .onOpenURL { url in
                guard url.scheme == "cutuque", url.host == "session" else { return }
                let id = url.lastPathComponent
                if !id.isEmpty { router.openSession(id) }
            }
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

/// Raiz do app: TabView com bottom bar alternando Sessões e Board.
struct RootTabView: View {
    @EnvironmentObject private var router: Router
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SessionListView()
                .tabItem { Label("Sessões", systemImage: "list.bullet.rectangle") }
                .tag(0)
            BoardView()
                .tabItem { Label("Board", systemImage: "rectangle.split.3x1") }
                .tag(1)
        }
        // Deep-link de sessão (push / Live Activity) volta pra aba Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { tab = 0 }
        }
    }
}
