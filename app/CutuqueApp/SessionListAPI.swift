import Foundation

/// A fatia do `APIClient` que a lista de sessões consome. Estreito de
/// propósito: `APIClient` tem 75 funcs, e um protocolo com todas elas seria
/// cerimônia sem leitor. Existe para que os dois flags de retrato
/// (`temRetratoDoRegistro`/`temRetratoDosVivos`) — que decidem quem vira aba
/// `.morta` — tenham teste (12/08/2026, achado `importante` da revisão da
/// fase 5).
@MainActor
protocol SessionListAPI {
    func sessions() async throws -> [Session]
    func targets() async throws -> [String]
    func tmuxList(machine: String) async -> [DiscoveredSession]
    func deleteSession(id: String) async throws
    func resolve(sessionID: String) async throws
    func tmuxKillServer(machine: String, socket: String) async throws
    func liveUpdates() -> AsyncStream<WSMessage>
}

extension APIClient: SessionListAPI {}
