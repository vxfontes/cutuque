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
/// `baseURL` e `token` vêm dos Ajustes (UserDefaults) — sem rebuild quando o
/// hub muda de casa (dev local → Tailscale → ZimaOS na Fase 5).
struct APIClient {
    // Lidos por request para refletir mudanças da tela de Ajustes na hora.
    var baseURL: URL { HubSettings.baseURL }
    var token: String { HubSettings.token }

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

    /// Lista os nomes das máquinas disponíveis. `GET /targets` (Bearer).
    /// Em qualquer falha (hub antigo sem o endpoint, offline, corpo inválido)
    /// devolve `[]` para a UI cair num fallback — nunca derruba a tela.
    func targets() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("targets"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder.cutuque.decode(TargetsEnvelope.self, from: data).targets
        } catch {
            // Hub em construção/offline: cai no fallback da UI.
            return []
        }
    }

    private struct TargetsEnvelope: Decodable {
        let targets: [String]
    }

    /// Apaga uma sessão. `DELETE /sessions/{id}` (Bearer).
    /// 200 → sucesso; 404 → `CutuqueError.notFound`.
    func deleteSession(id: String) async throws {
        let url = baseURL.appendingPathComponent("sessions").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await send(request)
    }

    /// Busca o histórico de output de uma sessão (últimos ~200 chunks), já
    /// classificado por `kind` (user/assistant/tool/tool_result) para o
    /// transcrito estilo chat. Se o endpoint ainda não existir (adapter em
    /// construção), devolve `[]` graciosamente.
    func output(sessionID: String) async throws -> [OutputChunk] {
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
        let chunks: [OutputChunk]
    }

    // MARK: - Status do hub (latência)

    /// Mede a latência do hub batendo em /health algumas vezes e devolvendo o
    /// melhor tempo (ms). online=false se nenhuma amostra respondeu 200.
    func healthLatency(samples: Int = 3) async -> (online: Bool, ms: Int?) {
        let url = baseURL.appendingPathComponent("health")
        var online = false
        var best: Double?
        for _ in 0..<max(1, samples) {
            let t0 = Date()
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let dt = Date().timeIntervalSince(t0) * 1000
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    online = true
                    best = min(best ?? dt, dt)
                }
            } catch {
                // amostra falhou; segue tentando as demais
            }
        }
        return (online, best.map { Int($0.rounded()) })
    }

    // MARK: - Ajustes (intervalo do re-cutucão)

    private struct RenudgeBody: Codable {
        let renudge_seconds: Int
    }

    /// Lê o intervalo atual do re-cutucão (segundos). `nil` se o hub não expõe
    /// (ex.: APNs desabilitado) — a tela usa um default nesse caso.
    func renudgeSeconds() async throws -> Int? {
        let url = baseURL.appendingPathComponent("settings").appendingPathComponent("renudge")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(RenudgeBody.self, from: data).renudge_seconds
    }

    /// Ajusta o intervalo do re-cutucão (segundos) via PUT /settings/renudge.
    func setRenudgeSeconds(_ seconds: Int) async throws {
        let url = baseURL.appendingPathComponent("settings").appendingPathComponent("renudge")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RenudgeBody(renudge_seconds: seconds))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Push (Fase 4)

    /// Registra o device token de APNs no hub. `POST /devices` (Bearer).
    /// Body: {"token":"<hex>","platform":"ios"}. Espera 200 {"ok":true}.
    func registerDevice(token deviceToken: String, platform: String = "ios") async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("devices"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "token": deviceToken, "platform": platform,
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Ações (Fase 3)

    /// Corpo de `POST /sessions`. `cwd` é opcional (pasta onde o claude roda);
    /// como é `Optional`, o encoder sintetizado usa `encodeIfPresent` e omite
    /// a chave inteira do JSON quando `nil` — não manda `"cwd": null`.
    private struct CreateSessionBody: Encodable {
        let machine: String
        let agent: String
        let prompt: String
        let cwd: String?
        let model: String?  // alias/nome do modelo (nil = default do claude)
        let effort: String? // low|medium|high|xhigh|max (nil = default)
    }

    /// Dispara uma nova sessão. `201` → Session; `400`/`504` → `CutuqueError.server`.
    /// `cwd` opcional: pasta onde o claude roda; vazio/nil = home da máquina.
    func createSession(machine: String, agent: String, prompt: String, cwd: String? = nil,
                       model: String? = nil, effort: String? = nil) async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Pasta em branco (só espaços) conta como "não informada".
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = CreateSessionBody(
            machine: machine, agent: agent, prompt: prompt,
            cwd: (trimmedCwd?.isEmpty ?? true) ? nil : trimmedCwd,
            model: (model?.isEmpty ?? true) ? nil : model,
            effort: (effort?.isEmpty ?? true) ? nil : effort
        )
        request.httpBody = try JSONEncoder().encode(body)

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

    /// Lista as sessões do Claude Code já existentes numa máquina (lidas de
    /// ~/.claude/projects lá), inclusive as não lançadas pelo Cutuque — a base
    /// para "acompanhar sessões ativas do Mac". `GET /machines/{machine}/sessions`.
    /// 200 → sessões; 404 → `[]` (hub antigo sem o endpoint, degradação graciosa);
    /// rede/502/etc → lança, para a UI distinguir "falhou" de "sem sessões".
    func discover(machine: String) async throws -> [DiscoveredSession] {
        let url = baseURL
            .appendingPathComponent("machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("sessions")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(DiscoverEnvelope.self, from: data).sessions
        case 404:
            return [] // hub antigo sem o endpoint → trata como "sem sessões"
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "o Mac não respondeu (tente de novo)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    private struct DiscoverEnvelope: Decodable {
        let sessions: [DiscoveredSession]
    }

    /// Lista as subpastas de um caminho no Mac (seletor de pastas ao criar uma
    /// sessão). path vazio = home da máquina. `GET /machines/{machine}/dirs?path=`.
    func listDirs(machine: String, path: String) async throws -> DirListing {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("machines").appendingPathComponent(machine).appendingPathComponent("dirs"),
            resolvingAgainstBaseURL: false
        )!
        if !path.isEmpty { comps.queryItems = [URLQueryItem(name: "path", value: path)] }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(DirListing.self, from: data)
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "o Mac não respondeu (tente de novo)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    /// Lista as sessões do Claude RODANDO agora numa máquina (processo vivo +
    /// transcript recente) — as "ao vivo" que aparecem na home.
    /// `GET /machines/{machine}/live`. Erros são engolidos em `[]` (é um poll de
    /// fundo; não deve poluir a home com alertas).
    func live(machine: String) async -> [DiscoveredSession] {
        let url = baseURL
            .appendingPathComponent("machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("live")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder.cutuque.decode(DiscoverEnvelope.self, from: data).sessions
        } catch {
            return []
        }
    }

    /// Lista os panes do tmux rodando claude na máquina (a ponte para observar/
    /// controlar sessões vivas de terminal). `GET /machines/{machine}/tmux`.
    /// Erros engolidos em `[]` (poll de fundo).
    func tmuxList(machine: String) async -> [DiscoveredSession] {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder.cutuque.decode(DiscoverEnvelope.self, from: data).sessions
        } catch {
            return []
        }
    }

    /// Captura a tela atual de um pane do tmux (o espelho ao vivo).
    /// `GET /machines/{machine}/tmux/screen?target=<pane>`. Vazio em falha.
    func tmuxScreen(machine: String, target: String) async -> String {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("machines").appendingPathComponent(machine)
                .appendingPathComponent("tmux").appendingPathComponent("screen"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "target", value: target)]
        guard let url = comps?.url else { return "" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct ScreenEnvelope: Decodable { let screen: String }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return "" }
            return try JSONDecoder().decode(ScreenEnvelope.self, from: data).screen
        } catch {
            return ""
        }
    }

    /// Fixa (cols>0) ou restaura (cols<=0) o tamanho da janela do pane, para o
    /// terminal caber bem no celular mesmo com o terminal do Mac enorme.
    /// `POST /machines/{machine}/tmux/resize`. Best-effort (falha silenciosa).
    func tmuxResize(machine: String, target: String, cols: Int, rows: Int) async {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux").appendingPathComponent("resize")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct ResizeBody: Encodable { let target: String; let cols: Int; let rows: Int }
        request.httpBody = try? JSONEncoder().encode(ResizeBody(target: target, cols: cols, rows: rows))
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Digita `text` no pane do tmux e submete (Enter) — a mensagem cai no
    /// terminal que já roda. `POST /machines/{machine}/tmux/keys`.
    func tmuxSendKeys(machine: String, target: String, text: String) async throws {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux").appendingPathComponent("keys")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["target": target, "text": text])
        try await send(request)
    }

    /// Envia uma TECLA NOMEADA (Ctrl+C, setas, Esc, Enter, Tab…) ao pane do tmux
    /// — pra interromper (Ctrl+C) e navegar o TUI (setas → subagentes).
    /// `POST /machines/{machine}/tmux/key`.
    func tmuxKey(machine: String, target: String, key: String) async throws {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux").appendingPathComponent("key")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["target": target, "key": key])
        try await send(request)
    }

    /// Encerra o pane do tmux (kill-pane): fecha o Claude daquele terminal.
    /// `POST /machines/{machine}/tmux/kill`. Destrutivo — a UI confirma antes.
    func tmuxKill(machine: String, target: String) async throws {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux").appendingPathComponent("kill")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["target": target])
        try await send(request)
    }

    /// Encerra o SERVIDOR tmux inteiro (todos os panes daquele socket).
    /// `POST /machines/{machine}/tmux/kill-server`. Destrutivo — a UI confirma antes.
    func tmuxKillServer(machine: String, socket: String) async throws {
        let url = baseURL
            .appendingPathComponent("machines").appendingPathComponent(machine)
            .appendingPathComponent("tmux").appendingPathComponent("kill-server")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["socket": socket])
        try await send(request)
    }

    /// Corpo de `POST /machines/{machine}/adopt`.
    private struct AdoptBody: Encodable {
        let id: String
        let cwd: String
        let title: String
    }

    /// Adota uma sessão descoberta: registra-a no hub (idle) para poder abri-la
    /// e continuar a conversa. `201` → Session. `POST /machines/{machine}/adopt`.
    func adopt(machine: String, discovered: DiscoveredSession) async throws -> Session {
        let url = baseURL
            .appendingPathComponent("machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("adopt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AdoptBody(id: discovered.id, cwd: discovered.cwd, title: discovered.title)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 201:
            return try JSONDecoder.cutuque.decode(SessionEnvelope.self, from: data).session
        case 400, 404:
            let message = Self.errorMessage(from: data) ?? "erro do servidor"
            throw CutuqueError.server(status: http.statusCode, message: message)
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    /// Corpo de POST /app/foreground. `at` (ms monotônicos) ordena updates que
    /// podem chegar fora de ordem no hub (SEC-102).
    private struct ForegroundBody: Encodable {
        let active: Bool
        let at: Int64
    }

    /// Informa ao hub se o app está em foreground. Enquanto ativo (heartbeat),
    /// o hub suprime push — o app já recebe tudo ao vivo pelo WS. `at` é um
    /// relógio monotônico do cliente para o hub aplicar a ORDEM lógica (não a de
    /// chegada na rede). `POST /app/foreground`. Falha silenciosa (best-effort).
    func setForeground(_ active: Bool, at: Int64) async {
        let url = baseURL.appendingPathComponent("app").appendingPathComponent("foreground")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ForegroundBody(active: active, at: at))
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Aprova o pedido de permissão pendente da sessão.
    func approve(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "approve")
    }

    /// Nega o pedido de permissão pendente da sessão.
    func deny(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "deny")
    }

    /// Marca a sessão como concluída (tira de needs_you) SEM apagá-la — usado
    /// pelo swipe "Concluir". `POST /sessions/{id}/resolve`.
    func resolve(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "resolve")
    }

    /// Pede ao hub pra importar o transcript do Mac dessa sessão, para o chat
    /// mostrar a conversa (recap) ao abrir uma sessão externa em vez de vazio.
    /// Best-effort: falha não impede abrir o detalhe. `POST /sessions/{id}/history`.
    func importHistory(sessionID: String) async {
        try? await postAction(sessionID: sessionID, action: "history")
    }

    /// Resposta em texto roteada pelo hub (tmux send-keys OU stdin) — usada pela
    /// resposta direto da notificação. `POST /sessions/{id}/reply`.
    func reply(sessionID: String, text: String) async throws {
        let url = baseURL
            .appendingPathComponent("sessions").appendingPathComponent(sessionID)
            .appendingPathComponent("reply")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        try await send(request)
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
