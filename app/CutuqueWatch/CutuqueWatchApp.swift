import SwiftUI

@main
struct CutuqueWatchApp: App {
    @StateObject private var conn = WatchConnector()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(conn)
                .onAppear { conn.activate() }
        }
    }
}
