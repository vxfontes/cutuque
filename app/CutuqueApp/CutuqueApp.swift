import SwiftUI

@main
struct CutuqueApp: App {
    // Liga o AppDelegate (device token + delegate de notificações) ao ciclo de vida.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Router de deep-link compartilhado (mesma instância usada pelo PushManager).
    @StateObject private var router = Router.shared
    // Estado de navegação do iPad. Mora aqui (e não na view raiz) porque a cena
    // `.commands` abaixo precisa alcançá-lo para emitir os atalhos ⌘ (Task 11).
    @StateObject private var nav = NavigationState()
    // Aparência (modo claro/escuro) + tema de cor, aplicados na raiz. @AppStorage
    // observa as chaves — mudou nos ajustes, re-aplica aqui na hora.
    @AppStorage(AppThemeKeys.colorScheme) private var colorSchemeRaw = AppColorScheme.system.rawValue
    @AppStorage(AppThemeKeys.accent) private var accentRaw = AppAccent.blue.rawValue
    // Fase da cena: informa o hub foreground/background (suprime push com o app aberto).
    @Environment(\.scenePhase) private var scenePhase
    // Board compartilhado: no iPad a coluna de filtros e o kanban são views
    // diferentes olhando o mesmo modelo.
    @StateObject private var board = BoardModel()

    var body: some Scene {
        WindowGroup {
            // A raiz é escolhida por IDIOM, não por classe de tamanho. Idiom
            // nunca muda em tempo de execução: o `if` roda uma vez e a árvore
            // jamais é remontada. Classe de tamanho mudaria (iPhone Pro Max em
            // paisagem é `.regular`) e trocar a raiz derrubaria o espelho do
            // tmux — é exatamente o que a decisão #19 evita.
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    RootSplitView()
                } else {
                    RootTabView()
                }
            }
            .environmentObject(router)
            .environmentObject(nav)
            .environmentObject(board)
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
        .commands { CutuqueCommands(nav: nav) }
        .onChange(of: scenePhase) { _, phase in
            ForegroundReporter.shared.update(phase)
        }
    }
}

/// Raiz do app: TabView com bottom bar alternando Sessões, Board e Máquinas.
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
            MachineListView()
                .tabItem { Label("Máquinas", systemImage: "server.rack") }
                .tag(2)
        }
        // Deep-link de sessão (push / Live Activity) volta pra aba Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { tab = 0 }
        }
    }
}
