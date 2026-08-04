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

    /// Lista as sessões passadas do histórico (Postgres). `GET /history` (Bearer).
    /// Hub sem histórico (sem Postgres) → 404; devolve [] gracioso.
    func history(limit: Int = 100) async throws -> [Session] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return [] } // 404 = histórico desligado no hub
        return try JSONDecoder.cutuque.decode(SessionsEnvelope.self, from: data).sessions
    }

    /// Linha do tempo de uma sessão do histórico. `GET /history/{id}/events`.
    func historyEvents(sessionID: String) async throws -> [HistoryEvent] {
        let url = baseURL.appendingPathComponent("history").appendingPathComponent(sessionID).appendingPathComponent("events")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { return [] }
        return try JSONDecoder.cutuque.decode(HistoryEventsEnvelope.self, from: data).events
    }

    private struct HistoryEventsEnvelope: Decodable {
        let events: [HistoryEvent]
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

    // MARK: - Cutuque Board (Kanban dos agentes)

    /// Lista os cards do quadro. `GET /board` (aberto; mandar o Bearer não atrapalha).
    func boardTasks() async throws -> [BoardTask] {
        var request = URLRequest(url: baseURL.appendingPathComponent("board"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.cutuque.decode(BoardEnvelope.self, from: data).tasks
    }

    private struct BoardEnvelope: Decodable { let tasks: [BoardTask] }

    /// Busca cards (ativos E arquivados) por título/descrição/comentário.
    /// `GET /board/search?q=`.
    func searchBoard(_ q: String) async throws -> [BoardTask] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("board").appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.cutuque.decode(BoardEnvelope.self, from: data).tasks
    }

    /// Semanas arquivadas (concluídos fechados por semana). `GET /board/archive`.
    func boardArchive() async throws -> [ArchivedWeek] {
        var request = URLRequest(url: baseURL.appendingPathComponent("board").appendingPathComponent("archive"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.cutuque.decode(ArchiveEnvelope.self, from: data).weeks
    }

    private struct ArchiveEnvelope: Decodable { let weeks: [ArchivedWeek] }

    /// Move um card de coluna. `PATCH /board/tasks/{id}` (aberto). `actor` alimenta o
    /// log de atividade (no app, a ação é da mantenedora → "você").
    func moveBoardTask(id: String, column: String) async throws {
        try await patchBoard(id: id, body: ["column": column, "actor": "você"])
    }

    /// Marca/desmarca um card como encalhado. Marcar volta o card pra "A fazer".
    func setBoardEncalhada(id: String, _ value: Bool) async throws {
        let body: [String: Any] = value
            ? ["column": "a_fazer", "encalhada": true, "actor": "você"]
            : ["encalhada": false, "actor": "você"]
        try await patchBoard(id: id, body: body)
    }

    private func patchBoard(id: String, body: [String: Any]) async throws {
        let url = baseURL.appendingPathComponent("board").appendingPathComponent("tasks").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await send(request)
    }

    /// Adiciona um comentário a um card. `POST /board/tasks/{id}/comments` (aberto).
    func addBoardComment(id: String, author: String, text: String) async throws {
        let url = baseURL.appendingPathComponent("board").appendingPathComponent("tasks").appendingPathComponent(id).appendingPathComponent("comments")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["author": author, "text": text])
        // 201 Created — trata como sucesso (o send só aceita 200/204).
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CutuqueError.unexpected(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Fecha a semana manualmente (arquiva concluídos + marca encalhados).
    /// `POST /board/close` — EXIGE token (só a mantenedora, via app/dashboard).
    /// `week` vazio = a semana do relógio; preenchido, arquiva NAQUELE rótulo —
    /// é como o trabalho da madrugada de segunda entra na semana que acabou.
    func closeWeek(week: String = "") async throws {
        var comps = URLComponents(url: baseURL.appendingPathComponent("board").appendingPathComponent("close"),
                                  resolvingAgainstBaseURL: false)!
        if !week.isEmpty { comps.queryItems = [URLQueryItem(name: "week", value: week)] }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await send(request)
    }

    /// As semanas candidatas a receber o fechamento. `GET /board/close-options`
    /// — mesmo dono do fechamento, mesmo token.
    func closeOptions() async throws -> CloseOptions {
        var request = URLRequest(url: baseURL.appendingPathComponent("board").appendingPathComponent("close-options"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder.cutuque.decode(CloseOptions.self, from: data)
    }

    /// Apaga um card do quadro. `DELETE /board/tasks/{id}` — EXIGE token (só a
    /// mantenedora, via app/dashboard). Agentes (CLI, sem token) recebem 401.
    func deleteBoardTask(id: String) async throws {
        let url = baseURL.appendingPathComponent("board").appendingPathComponent("tasks").appendingPathComponent(id)
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
        let model: String?   // alias/nome do modelo (nil = default do agente)
        let effort: String?  // low|medium|high|… (nil = default)
        let sandbox: String? // só Codex: read-only|workspace-write|danger-full-access
    }

    /// Dispara uma nova sessão. `201` → Session; `400`/`504` → `CutuqueError.server`.
    /// `cwd` opcional: pasta onde o claude roda; vazio/nil = home da máquina.
    func createSession(machine: String, agent: String, prompt: String, cwd: String? = nil,
                       model: String? = nil, effort: String? = nil, sandbox: String? = nil) async throws -> Session {
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
            effort: (effort?.isEmpty ?? true) ? nil : effort,
            sandbox: (sandbox?.isEmpty ?? true) ? nil : sandbox
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

    // MARK: - Aba Máquinas

    /// GET autenticado que decodifica JSON, usado pelos endpoints da aba
    /// Máquinas. Os métodos mais antigos montam o request na mão e ficam como
    /// estão — não vale reescrever tudo agora.
    private func getJSON<T: Decodable>(_ segments: [String], query: [URLQueryItem] = []) async throws -> T {
        let url = segments.reduce(baseURL) { $0.appendingPathComponent($1) }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(T.self, from: data)
        case 404:
            throw CutuqueError.notFound
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "a máquina não respondeu (tente de novo)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    /// Lista as máquinas que o hub conhece, com destino e origem. `GET /machines`.
    /// Diferente de `targets()`, que devolve só os nomes para criar sessão.
    func listMachines() async throws -> [Machine] {
        let envelope: MachinesEnvelope = try await getJSON(["machines"])
        return envelope.machines
    }

    private struct MachinesEnvelope: Decodable {
        let machines: [Machine]
    }

    // MARK: - Cadastro de máquinas (aba Máquinas)

    /// Cadastra uma máquina nova associada a uma identidade JÁ existente. O hub
    /// gera o par de chaves da identidade (se ainda não tinha) e devolve a
    /// PÚBLICA mais a impressão digital do host para conferência. `POST /machines`.
    ///
    /// Nada é confiado aqui: o cadastro nasce sem impressão confirmada e a
    /// máquina só vira utilizável depois do `trustMachine`.
    func createMachine(name: String, host: String, port: Int, identity: String, theme: String) async throws -> MachineCreated {
        try await machineJSON(
            "POST", ["machines"],
            body: ["name": name, "host": host, "port": port, "identity": identity, "theme": theme],
            ok: 201
        )
    }

    /// Relê a impressão digital que o host está apresentando agora, para
    /// conferência. `GET /machines/{n}/scan`.
    ///
    /// É o que salva um cadastro abandonado no meio: a impressão do
    /// `createMachine` só existe naquela resposta, e sem isto a máquina ficaria
    /// pendente para sempre.
    func scanMachine(name: String) async throws -> String {
        struct Resp: Decodable { let fingerprint: String }
        let resp: Resp = try await machineJSON("GET", ["machines", name, "scan"], body: nil)
        return resp.fingerprint
    }

    /// Confirma a impressão digital do host. O hub escaneia DE NOVO e compara —
    /// host trocado depois do cadastro é recusado aqui. `POST /machines/{n}/trust`.
    @discardableResult
    func trustMachine(name: String, fingerprint: String) async throws -> Machine {
        let envelope: MachineEnvelope = try await machineJSON(
            "POST", ["machines", name, "trust"],
            body: ["fingerprint": fingerprint]
        )
        return envelope.machine
    }

    /// Instala a chave da identidade da máquina no destino. `password` vazio ⇒
    /// usa a senha JÁ GUARDADA na identidade (se ela tiver uma — senão o hub
    /// responde `no_password`). `POST /machines/{n}/install-key`.
    ///
    /// Quando informada, a senha é de uso único: vai no corpo desta chamada e
    /// não é guardada nem aqui nem no hub (a menos que a chamadora peça
    /// explicitamente via `updateIdentity`, à parte). Só funciona depois do
    /// trust — mandar senha para um host não conferido seria entregá-la a
    /// quem estiver no meio.
    func installKey(name: String, password: String = "") async throws {
        let _: OKResponse = try await machineJSON(
            "POST", ["machines", name, "install-key"],
            body: ["password": password]
        )
    }

    /// Detecta o sistema operacional do host e devolve a máquina com `os`
    /// preenchido (alimenta `machine.osIcon`). `POST /machines/{n}/detect-os`.
    /// Falhar aqui NÃO invalida o cadastro — é só o ícone; a chamadora decide
    /// tratar como aviso, não como erro fatal.
    @discardableResult
    func detectOS(name: String) async throws -> Machine {
        let envelope: MachineEnvelope = try await machineJSON("POST", ["machines", name, "detect-os"], body: nil)
        return envelope.machine
    }

    /// Altera host, porta, identidade ou tema de uma máquina cadastrada pelo
    /// app. Campo vazio = mantém o atual (regra do hub). `PATCH /machines/{n}`.
    ///
    /// Mudar o endereço derruba a confirmação do host: a máquina volta a pedir
    /// conferência da impressão digital antes de conectar de novo.
    @discardableResult
    func updateMachine(name: String, host: String, port: Int, identity: String, theme: String) async throws -> Machine {
        let envelope: MachineEnvelope = try await machineJSON(
            "PATCH", ["machines", name],
            body: ["host": host, "port": port, "identity": identity, "theme": theme]
        )
        return envelope.machine
    }

    /// Troca o tema do terminal e o ícone da máquina.
    /// `PUT /machines/{n}/appearance`.
    ///
    /// PUT e não PATCH: aqui vazio é ESCOLHA — `theme: ""` é o tema Padrão e
    /// `icon: ""` é o ícone automático (pelo SO). Pelo `updateMachine` isso seria
    /// impossível, porque lá vazio significa "mantém o atual". Os dois campos vão
    /// sempre juntos: é substituição, não patch.
    ///
    /// Não encosta em host, porta, identidade nem impressão digital — trocar de
    /// cor nunca derruba a confiança do host.
    @discardableResult
    func setAppearance(name: String, theme: String, icon: String) async throws -> Machine {
        let envelope: MachineEnvelope = try await machineJSON(
            "PUT", ["machines", name, "appearance"],
            body: ["theme": theme, "icon": icon]
        )
        return envelope.machine
    }

    /// Descadastra a máquina. NÃO apaga chave nenhuma — desde o redesenho a
    /// chave é da identidade (reutilizada por outros hosts); quem apaga é o
    /// `DELETE /identities/{id}`. `DELETE /machines/{n}`.
    func deleteMachine(name: String) async throws {
        _ = try await machineRequest("DELETE", ["machines", name], body: nil, ok: 204)
    }

    // MARK: - Identidades (aba Máquinas)
    //
    // Desde o redesenho no modelo Termius, usuário/chave/senha vivem na
    // identidade — reutilizável entre hosts — e não mais na máquina.

    /// Lista as identidades cadastradas, mais se o hub consegue guardar senha
    /// cifrada (`canStorePassword` — controla se o campo de senha aparece ao
    /// criar uma identidade nova). `GET /identities`.
    func listIdentities() async throws -> IdentityListResponse {
        try await getJSON(["identities"])
    }

    /// Cria uma identidade nova. `password` vazia = identidade só de chave (o
    /// hub gera o par ed25519 de qualquer forma; só a chave PÚBLICA volta).
    /// `POST /identities`.
    func createIdentity(name: String, username: String, password: String) async throws -> IdentityCreated {
        try await identityJSON(
            "POST", ["identities"],
            body: ["name": name, "username": username, "password": password],
            ok: 201
        )
    }

    /// Altera usuário e/ou senha de uma identidade. `password: nil` OMITE o
    /// campo do JSON (mantém a senha guardada); `""` APAGA; texto novo troca.
    /// NUNCA mande `""` sem querer apagar — é a diferença entre "mantém" e
    /// "apaga o segredo da usuária sem ela pedir". `PATCH /identities/{n}`.
    @discardableResult
    func updateIdentity(name: String, username: String, password: String?) async throws -> Identity {
        let body = Self.identityUpdateBody(username: username, password: password)
        let envelope: IdentityEnvelope = try await identityJSON("PATCH", ["identities", name], body: body)
        return envelope.identity
    }

    /// Monta o corpo do PATCH acima — extraído (puro, sem rede) pra dar pra
    /// testar a regra de ouro sem mock de rede: `nil` não entra no dicionário
    /// (mantém), `""` entra como string vazia (apaga).
    static func identityUpdateBody(username: String, password: String?) -> [String: Any] {
        var body: [String: Any] = ["username": username]
        if let password { body["password"] = password }
        return body
    }

    /// Apaga uma identidade — recusado (409) se alguma máquina ainda a usa.
    /// `DELETE /identities/{n}`.
    func deleteIdentity(name: String) async throws {
        _ = try await identityRequest("DELETE", ["identities", name], body: nil, ok: 204)
    }

    /// Dispara uma chamada de identidade e decodifica o corpo de sucesso.
    /// Espelha `machineJSON`/`machineRequest`, só trocando o tradutor de erro
    /// (`identityErrorMessage`) — rotas diferentes, códigos de erro diferentes.
    private func identityJSON<T: Decodable>(
        _ method: String, _ segments: [String],
        body: [String: Any]?, ok: Int = 200
    ) async throws -> T {
        let data = try await identityRequest(method, segments, body: body, ok: ok)
        return try JSONDecoder.cutuque.decode(T.self, from: data)
    }

    private func identityRequest(
        _ method: String, _ segments: [String],
        body: [String: Any]?, ok: Int
    ) async throws -> Data {
        let url = segments.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode != ok else { return data }
        throw CutuqueError.server(
            status: http.statusCode,
            message: Self.identityErrorMessage(from: data, status: http.statusCode)
        )
    }

    /// Traduz o erro de identidade para uma frase acionável — mesmo molde de
    /// `machineErrorMessage` (detalhe do hub ganha de qualquer mapa fixo).
    static func identityErrorMessage(from data: Data, status: Int) -> String {
        struct Body: Decodable {
            let error: String?
            let detail: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if let detail = body?.detail, !detail.isEmpty { return detail }
        switch body?.error {
        case "invalid_identity":      return "nome ou usuário inválido"
        case "cannot_store_password": return "este hub não guarda senha — cadastre só com chave"
        case "duplicate_identity":    return "já existe uma identidade com esse nome"
        case "unknown_identity":      return "identidade não encontrada"
        case "identity_in_use":       return "identidade em uso por uma ou mais máquinas — remova das máquinas primeiro"
        case let other?:              return other
        case nil:                     return "erro inesperado (\(status))"
        }
    }

    private struct OKResponse: Decodable { let ok: Bool }

    /// Dispara uma chamada do cadastro e decodifica o corpo de sucesso.
    private func machineJSON<T: Decodable>(
        _ method: String, _ segments: [String],
        body: [String: Any]?, ok: Int = 200
    ) async throws -> T {
        let data = try await machineRequest(method, segments, body: body, ok: ok)
        return try JSONDecoder.cutuque.decode(T.self, from: data)
    }

    /// Chamada crua do cadastro, com o erro do hub por extenso.
    ///
    /// As rotas de cadastro respondem `{"error": código, "detail": "..."}`, e o
    /// detalhe é justamente o que a usuária precisa ler: "a máquina respondeu
    /// com SHA256:X e você confirmou SHA256:Y" é a diferença entre desistir e
    /// entender que o host mudou. O `send` genérico jogaria isso fora.
    private func machineRequest(
        _ method: String, _ segments: [String],
        body: [String: Any]?, ok: Int
    ) async throws -> Data {
        let url = segments.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode != ok else { return data }
        throw CutuqueError.server(
            status: http.statusCode,
            message: Self.machineErrorMessage(from: data, status: http.statusCode)
        )
    }

    /// Traduz o erro do cadastro para uma frase que dá para agir. Quando o hub
    /// manda `detail`, ele ganha: é a única parte que fala do caso concreto.
    static func machineErrorMessage(from data: Data, status: Int) -> String {
        struct Body: Decodable {
            let error: String?
            let detail: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if let detail = body?.detail, !detail.isEmpty { return detail }
        switch body?.error {
        case "duplicate_name":       return "já existe uma máquina com esse nome"
        case "invalid_machine":      return "nome ou destino inválido"
        case "read_only":            return "essa máquina vem do hub.env — quem manda nela é o hub"
        case "unknown_machine":      return "máquina não encontrada"
        case "not_trusted":          return "confirme a impressão digital antes de instalar a chave"
        case "fingerprint_mismatch": return "a chave do host não é a que você confirmou"
        case "scan_failed":          return "não deu para falar com o host (endereço, porta ou rede)"
        case "install_failed":       return "o host recusou — confira a senha e se o usuário existe"
        case "keygen_failed":        return "o hub não conseguiu gerar a chave"
        case "unknown_identity":     return "identidade não encontrada — escolha outra"
        case "no_password":          return "sem senha guardada na identidade — digite uma para instalar a chave"
        case let other?:             return other
        case nil:                    return "erro inesperado (\(status))"
        }
    }

    /// Lista pastas E arquivos de um caminho na máquina (navegador de arquivos).
    /// path vazio = home. `GET /machines/{machine}/fs?path=`.
    func listFiles(machine: String, path: String) async throws -> FileListing {
        try await getJSON(
            ["machines", machine, "fs"],
            query: path.isEmpty ? [] : [URLQueryItem(name: "path", value: path)]
        )
    }

    /// Lê um arquivo de texto da máquina. Binário ou grande demais volta marcado
    /// e sem conteúdo. `GET /machines/{machine}/fs/read?path=`.
    func readFile(machine: String, path: String) async throws -> FileContent {
        try await getJSON(
            ["machines", machine, "fs", "read"],
            query: [URLQueryItem(name: "path", value: path)]
        )
    }

    /// Salva um arquivo de texto na máquina. Só sobrescreve arquivo que já
    /// existe: se sumiu (ou virou pasta) desde que foi aberto, o hub devolve 404
    /// e isto vira `.notFound`. `PUT /machines/{machine}/fs/write`.
    @discardableResult
    func writeFile(machine: String, path: String, content: String) async throws -> FileWrite {
        let url = baseURL
            .appendingPathComponent("machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("fs")
            .appendingPathComponent("write")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FileWriteRequest(path: path, content: content))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder.cutuque.decode(FileWrite.self, from: data)
        case 404:
            throw CutuqueError.notFound
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "não deu para salvar (a máquina não respondeu)")
        default:
            throw CutuqueError.unexpected(status: http.statusCode)
        }
    }

    /// Corpo do PUT de escrita. O conteúdo vai como string JSON (texto), não
    /// base64: o editor só abre arquivo de texto.
    private struct FileWriteRequest: Encodable {
        let path: String
        let content: String
    }

    /// URL autenticável do download de um arquivo — usada pelo `downloadFile`.
    /// Isolada para o teste conferir a montagem sem tocar a rede.
    func downloadURL(machine: String, path: String) -> URL {
        let url = baseURL
            .appendingPathComponent("machines")
            .appendingPathComponent(machine)
            .appendingPathComponent("fs")
            .appendingPathComponent("download")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return comps.url!
    }

    /// Baixa os bytes crus de um arquivo (inclusive binário) para um arquivo
    /// temporário e devolve a URL local, pronta para o ShareLink.
    /// `GET /machines/{machine}/fs/download?path=`.
    func downloadFile(machine: String, path: String) async throws -> URL {
        var request = URLRequest(url: downloadURL(machine: machine, path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            // Subpasta única por download: dois arquivos de mesmo nome, de
            // máquinas diferentes, não podem se sobrescrever no tmp.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = (path as NSString).lastPathComponent
            let dest = dir.appendingPathComponent(name.isEmpty ? "arquivo" : name)
            try data.write(to: dest)
            return dest
        case 404:
            throw CutuqueError.notFound
        case 502, 503:
            throw CutuqueError.server(status: http.statusCode, message: "não deu para baixar (a máquina não respondeu)")
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
        let agent: String
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
            AdoptBody(id: discovered.id, cwd: discovered.cwd, title: discovered.title, agent: discovered.agent)
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

    /// Liga/desliga TODAS as notificações do hub para o app (interruptor mestre
    /// "Cutuque ativo"). active=false = o hub para de cutucar (push + Live Activity).
    func setActive(_ active: Bool) async {
        let url = baseURL.appendingPathComponent("app").appendingPathComponent("active")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["active": active])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Aprova o pedido de permissão pendente da sessão.
    func approve(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "approve")
    }

    /// Nega o pedido de permissão pendente da sessão. Também usado para
    /// CANCELAR uma pergunta de seleção pendente (o hub aceita deny de
    /// pergunta; NÃO existe "aprovar" pergunta — só responder ou cancelar).
    func deny(sessionID: String) async throws {
        try await postAction(sessionID: sessionID, action: "deny")
    }

    /// Corpo de sucesso de `POST /sessions/{id}/interrupt`: `effect` diz o que
    /// REALMENTE aconteceu — "paused" (sessão tmux-adotada, Esc no pane, a
    /// sessão CONTINUA rodando) ou "ended" (sessão pipe-mode, sem primitiva de
    /// interrupt suave no protocolo do CLI headless hoje — o hub encerra o
    /// processo; a sessão vai a done/error e precisa de nova mensagem/--resume).
    private struct InterruptResponse: Decodable {
        let ok: Bool
        let effect: String
    }

    /// Interrompe o turno em andamento da sessão (card 6b74500a1fd9a1f2).
    /// `POST /sessions/{id}/interrupt`. Só faz sentido com `state == .running`
    /// — fora disso o hub devolve 409 (`CutuqueError.staleState`). Devolve o
    /// `effect` ("paused"/"ended") para a UI avisar corretamente qual dos
    /// dois ocorreu — NUNCA assuma de antemão qual vai ser.
    func interrupt(sessionID: String) async throws -> String {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("interrupt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(InterruptResponse.self, from: data).effect
        case 404:
            throw CutuqueError.notFound
        case 409:
            // Cobre tanto "stale_state" (saiu de running) quanto "no_live_session"
            // (sem processo vivo pra interromper) — os dois significam "o estado
            // que você assumia não é mais válido", mesma convenção do resto do app.
            throw CutuqueError.staleState
        default:
            let message = Self.errorMessage(from: data) ?? "erro do servidor"
            throw CutuqueError.server(status: http.statusCode, message: message)
        }
    }

    /// Um item de resposta a uma pergunta de seleção: `question` é o texto
    /// EXATO da pergunta (como veio em `pending_questions`); `selected` são os
    /// labels escolhidos (1 para seleção única, N para múltipla) — ou o texto
    /// livre digitado em "Outro", sem marcador especial.
    struct AnswerItem: Encodable {
        let question: String
        let selected: [String]
    }

    private struct AnswerBody: Encodable {
        let answers: [AnswerItem]
    }

    /// Responde a uma ou mais perguntas de seleção pendentes (ferramenta
    /// AskUserQuestion). `POST /sessions/{id}/answer`. IMPORTANTE: pergunta
    /// NÃO se aprova por `/approve` (o hub rejeita com 409) — só por aqui, ou
    /// por `deny(sessionID:)` para cancelar.
    func answer(sessionID: String, answers: [AnswerItem]) async throws {
        let url = baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("answer")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AnswerBody(answers: answers))
        try await send(request)
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
        case 200, 204:  return   // 204 No Content (ex.: DELETE do board) também é sucesso
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
