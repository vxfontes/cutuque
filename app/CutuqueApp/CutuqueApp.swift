import SwiftUI

@main
struct CutuqueApp: App {
    var body: some Scene {
        WindowGroup {
            // Lista de sessões é a tela raiz da Fase 1.
            NavigationStack {
                SessionListView()
            }
        }
    }
}
