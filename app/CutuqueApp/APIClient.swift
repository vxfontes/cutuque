import Foundation

/// Cliente do hub Cutuque (REST + WebSocket).
/// `baseURL` e `token` são constantes fáceis de trocar (dev → Tailscale na Fase 5).
struct APIClient {
    // Em dev o hub roda local; no simulador 127.0.0.1 = localhost do Mac.
    var baseURL = URL(string: "http://127.0.0.1:8787")!
    var token = "dev-token"

    // MARK: - REST

    /// Busca a lista atual de sessões. `Authorization: Bearer <token>`.
    func sessions() async throws -> [Session] {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // O hub responde { "sessions": [...] }.
        let envelope = try JSONDecoder.cutuque.decode(SessionsEnvelope.self, from: data)
        return envelope.sessions
    }

    private struct SessionsEnvelope: Decodable {
        let sessions: [Session]
    }

    /// Busca o histórico de output de uma sessão (últimos ~200 chunks).
    /// Se o endpoint ainda não existir (adapter em construção), devolve `[]` graciosamente.
    func output(sessionID: String) async throws -> [String] {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("output")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // Endpoint ainda não implementado no hub → sem output (estado vazio gracioso).
        guard http.statusCode == 200 else { return [] }

        let envelope = try JSONDecoder.cutuque.decode(OutputEnvelope.self, from: data)
        return envelope.chunks
    }

    private struct OutputEnvelope: Decodable {
        let chunks: [String]
    }

    // MARK: - WebSocket ao vivo

    /// Stream de mensagens do /ws com reconexão automática.
    /// Ao conectar chega um `snapshot`; depois, `session_updated` a cada mudança.
    /// Se a conexão cair, reconecta com backoff exponencial (1s → 10s).
    func liveUpdates() -> AsyncStream<WSMessage> {
        // Captura os valores locais para não depender de `self` dentro da Task.
        let base = baseURL
        let token = token

        return AsyncStream { continuation in
            let task = Task {
                let initialDelay: UInt64 = 1_000_000_000  // 1s
                let maxDelay: UInt64 = 10_000_000_000      // 10s
                var delay = initialDelay

                while !Task.isCancelled {
                    let ws = URLSession.shared.webSocketTask(with: Self.wsURL(base: base, token: token))
                    ws.resume()

                    do {
                        // Loop de recepção enquanto a conexão estiver viva.
                        while !Task.isCancelled {
                            let message = try await ws.receive()
                            if let msg = Self.decode(message) {
                                continuation.yield(msg)
                            }
                            delay = initialDelay // conexão saudável → zera o backoff
                        }
                    } catch {
                        // Conexão caiu (ou erro de recepção) → cai para reconexão.
                    }

                    ws.cancel(with: .goingAway, reason: nil)
                    if Task.isCancelled { break }

                    // Espera antes de tentar de novo, com backoff limitado.
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, maxDelay)
                }
                continuation.finish()
            }

            // Ao cancelar o consumo do stream, encerra a Task e o WebSocket.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Monta ws://host/ws?token=... a partir da baseURL http.
    private static func wsURL(base: URL, token: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    /// Decodifica uma mensagem recebida (string ou binária) em `WSMessage`.
    private static func decode(_ message: URLSessionWebSocketTask.Message) -> WSMessage? {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw):    data = raw
        @unknown default:       data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder.cutuque.decode(WSMessage.self, from: data)
    }
}
