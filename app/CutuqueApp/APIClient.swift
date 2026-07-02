import Foundation

/// Erros tipados do hub Cutuque, com mensagem amigável para a UI.
enum CutuqueError: LocalizedError, Equatable {
    /// 400/504 — carrega o status HTTP e a mensagem devolvida pelo servidor.
    case server(status: Int, message: String)
    /// 409 — o estado da sessão mudou entre a leitura e a ação.
    case staleState
    /// 404 — sessão inexistente.
    case notFound
    /// Qualquer outro status inesperado.
    case unexpected(status: Int)

    var errorDescription: String? {
        switch self {
        case .server(_, let message): return message
        case .staleState:             return "o estado mudou"
        case .notFound:               return "sessão não encontrada"
        case .unexpected(let status): return "erro inesperado (\(status))"
        }
    }
}

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

    // MARK: - Push (Fase 4)

    /// Registra o device token de APNs no hub. `POST /devices` (Bearer).
    /// Body: {"token":"<hex>","platform":"ios"}. Espera 200 {"ok":true}.
    func registerDevice(token deviceToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("devices"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "token": deviceToken, "platform": "ios",
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Ações (Fase 3)

    /// Dispara uma nova sessão. `201` → Session; `400`/`504` → `CutuqueError.server`.
    func createSession(machine: String, agent: String, prompt: String) async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "machine": machine, "agent": agent, "prompt": prompt,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 201:
            return try JSONDecoder.cutuque.decode(SessionEnvelope.self, from: data).session
        case 400, 504:
            // Ex.: {"error":"unknown_machine"} ou {"error":"launch_timeout"}.
            let message = Self.errorMessage(from: data) ?? "erro do servidor"
            throw CutuqueError.server(status: http.statusCode, message: message)
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    /// Aprova o pedido de permissão pendente da sessão.
    func approve(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "approve")
    }

    /// Nega o pedido de permissão pendente da sessão.
    func deny(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "deny")
    }

    /// Envia texto livre como resposta ao agente.
    func sendInput(sessionID: String, text: String) async throws {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("input")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        try await send(request)
    }

    // MARK: Helpers das ações

    private func postAction(sessionID: String, action: String) async throws {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent(action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await send(request)
    }

    /// Dispara o request e mapeia status → erro tipado (200 = sucesso silencioso).
    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:  return
        case 404:  throw CutuqueError.notFound
        case 409:  throw CutuqueError.staleState
        default:   throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    private struct SessionEnvelope: Decodable {
        let session: Session
    }

    /// Extrai `{"error":"..."}` de uma resposta de erro, se presente.
    private static func errorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable { let error: String }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
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
