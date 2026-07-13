import SwiftUI

// MARK: - Estado da sessão

/// Estados possíveis de uma sessão de agente, conforme contrato do hub.
/// Cada estado tem uma cor associada usada nas bolinhas da lista.
enum SessionState: String, Codable {
    case running    // rodando
    case needsYou   // precisa de você (needs_you no wire)
    case done       // concluído
    case error      // falhou
    case idle       // ocioso

    // O hub usa snake_case no valor (ex.: "needs_you"), então mapeamos manualmente.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running":   self = .running
        case "needs_you": self = .needsYou
        case "done":      self = .done
        case "error":     self = .error
        case "idle":      self = .idle
        default:          self = .idle // desconhecido cai em idle (defensivo)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    /// Valor exato usado no protocolo (snake_case).
    var wireValue: String {
        switch self {
        case .running:  return "running"
        case .needsYou: return "needs_you"
        case .done:     return "done"
        case .error:    return "error"
        case .idle:     return "idle"
        }
    }

    /// Cor da bolinha de estado.
    var color: Color {
        switch self {
        case .running:  return .blue
        case .needsYou: return .orange
        case .done:     return .green
        case .error:    return .red
        case .idle:     return .gray
        }
    }

    /// Rótulo textual em português exibido na lista.
    var label: String {
        switch self {
        case .running:  return "rodando"
        case .needsYou: return "precisa de você"
        case .done:     return "concluído"
        case .error:    return "falhou"
        case .idle:     return "ocioso"
        }
    }
}

// MARK: - Chunks de output (transcrito estilo chat)

/// Tipo de um pedaço de output, conforme o contrato novo do hub.
/// Determina como o chunk é desenhado no transcrito: bolha do usuário,
/// texto do assistente, ou linha discreta de ferramenta/resultado.
enum ChunkKind: Decodable, Equatable {
    case user
    case assistant
    case tool
    case toolResult

    // O hub usa snake_case no valor (ex.: "tool_result"), então mapeamos manualmente.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "user":        self = .user
        case "assistant":   self = .assistant
        case "tool":        self = .tool
        case "tool_result": self = .toolResult
        default:            self = .assistant // desconhecido cai em assistente (defensivo)
        }
    }
}

/// Um pedaço de output do histórico (`GET /sessions/{id}/output`), já
/// classificado por tipo. `id` é só local (não vem do wire) — serve para
/// identidade estável em listas SwiftUI.
struct OutputChunk: Decodable, Identifiable, Equatable {
    let id = UUID()
    let kind: ChunkKind
    let text: String

    private enum CodingKeys: String, CodingKey {
        case kind, text
    }
}

// MARK: - Pergunta de seleção (AskUserQuestion)

/// Uma opção de resposta para uma pergunta de seleção, com rótulo em destaque
/// e descrição opcional em texto corrido.
struct QuestionOption: Codable, Equatable, Hashable, Identifiable {
    let label: String
    let description: String?
    var id: String { label }
}

/// Uma pergunta de seleção pendente (única ou múltipla). Presente no
/// `pending_questions` da sessão quando o pedido pendente NÃO é uma permissão
/// comum sim/não, e sim uma pergunta com opções (ferramenta AskUserQuestion do
/// Claude Code). `header` é curto (≤12 chars, ex.: "Cor"); `question` é o
/// texto exato a devolver em `POST /answer`.
struct PendingQuestion: Codable, Equatable, Hashable, Identifiable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QuestionOption]
    var id: String { question }
}

// MARK: - Sessão

/// Uma sessão de agente reportada pelo hub.
/// Chaves em snake_case são resolvidas via `convertFromSnakeCase` no decoder compartilhado.
struct Session: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let machine: String
    let agent: String
    let title: String
    let state: SessionState
    let createdAt: Date
    let updatedAt: Date
    /// Texto do pedido de permissão/pergunta quando `state == .needsYou`.
    /// Opcional: pode faltar no payload (decode de `pending_prompt` via snake_case).
    let pendingPrompt: String?
    /// Alvo tmux ("<socket>\t<pane>") quando a sessão roda dentro do tmux (veio
    /// de hook com $TMUX). Vazio/nil = sessão local fora do tmux. Permite abrir o
    /// terminal ao vivo exato dessa sessão.
    let pane: String?
    /// True se a sessão NÃO foi lançada pelo app (hook do Claude / adoção). Nessas
    /// o hub não controla o gate de permissão — nada de aprovar/negar; a resposta
    /// é no terminal.
    let external: Bool?
    /// Pasta onde a sessão roda (para a árvore no detalhe/ao-vivo).
    let cwd: String?
    /// Perguntas de seleção pendentes (ferramenta AskUserQuestion), quando o
    /// pedido pendente NÃO é uma permissão comum sim/não. Ausente/nil = pedido
    /// comum (aprovar/negar como antes). 1 a 4 perguntas.
    let pendingQuestions: [PendingQuestion]?

    // pane/external/cwd/pendingQuestions podem faltar em respostas de um hub antigo → default seguro.
    private enum CodingKeys: String, CodingKey {
        case id, machine, agent, title, state, createdAt, updatedAt, pendingPrompt, pane, external, cwd, pendingQuestions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(String.self, forKey: .machine)
        agent = try c.decode(String.self, forKey: .agent)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decode(SessionState.self, forKey: .state)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pendingPrompt = try? c.decode(String.self, forKey: .pendingPrompt)
        pane = try? c.decode(String.self, forKey: .pane)
        external = try? c.decode(Bool.self, forKey: .external)
        cwd = try? c.decode(String.self, forKey: .cwd)
        pendingQuestions = try? c.decode([PendingQuestion].self, forKey: .pendingQuestions)
    }
    /// True quando é uma sessão externa (hook/adoção) — o app NÃO mostra
    /// aprovar/negar (a resposta é no terminal do Mac).
    var isExternal: Bool { external ?? false }

    /// Alvo tmux não-vazio, se a sessão for de terminal ao vivo.
    var tmuxTarget: String? {
        guard let p = pane, !p.isEmpty else { return nil }
        return p
    }
}

// MARK: - Sessão descoberta (acompanhar sessões do Mac)

/// Uma sessão do Claude Code já existente numa máquina, lida de
/// `~/.claude/projects` lá (`GET /machines/{machine}/sessions`), inclusive as
/// não lançadas pelo Cutuque. É "descoberta" (ainda não adotada): ao tocar,
/// o app a adota (registra no hub) e abre para continuar a conversa.
struct DiscoveredSession: Decodable, Identifiable, Equatable, Hashable {
    let id: String        // = session_id (nome do arquivo .jsonl)
    let cwd: String       // pasta onde a sessão roda
    let title: String     // primeira mensagem do usuário
    let last: String      // última mensagem do usuário (preview)
    let count: Int        // nº de mensagens do usuário (preview)
    let modified: Int64   // mtime do transcript (epoch em segundos)
    let state: String     // "running"|"waiting"|"idle" (só panes vivos do tmux; lido do terminal)
    let agent: String     // "claude-code"|"codex" (qual agente gerou a sessão)

    /// Instante da última atividade, derivado do mtime.
    var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }

    /// Último componente da pasta (ex.: "personal") para rótulo compacto.
    var folderName: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? cwd
    }

    /// Componentes da pasta (para a "árvore" no preview), sem o "/" inicial.
    var pathComponents: [String] {
        cwd.split(separator: "/").map(String.init)
    }

    // Campos novos podem faltar em respostas de um hub antigo → default seguro.
    private enum CodingKeys: String, CodingKey { case id, cwd, title, last, count, modified, state, agent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decode(String.self, forKey: .title)
        last = (try? c.decode(String.self, forKey: .last)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        modified = (try? c.decode(Int64.self, forKey: .modified)) ?? 0
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        // Hub antigo não manda agent → assume claude-code (legado).
        agent = (try? c.decode(String.self, forKey: .agent)) ?? "claude-code"
    }

    /// Init direto (para sintetizar uma entrada viva a partir de uma sessão do
    /// registry que tem um pane tmux).
    init(id: String, cwd: String, title: String, last: String = "", count: Int = 0, modified: Int64 = 0, state: String = "", agent: String = "claude-code") {
        self.id = id; self.cwd = cwd; self.title = title
        self.last = last; self.count = count; self.modified = modified; self.state = state; self.agent = agent
    }
}

// MARK: - Histórico (event-log persistido)

/// Um evento na linha do tempo de uma sessão passada (GET /history/{id}/events).
struct HistoryEvent: Decodable, Identifiable, Hashable {
    let seq: Int64
    let at: Date
    let type: String      // session_started|output_chunk|needs_input|user_responded|finished|errored
    let kind: String      // user|assistant|tool|tool_result (só em output_chunk)
    let data: String
    var id: Int64 { seq }

    private enum CodingKeys: String, CodingKey { case seq, at, type, kind, data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date(timeIntervalSince1970: 0)
        type = try c.decode(String.self, forKey: .type)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        data = (try? c.decode(String.self, forKey: .data)) ?? ""
    }
}

// MARK: - Seletor de pastas

/// Uma subpasta no Mac (item do seletor de pastas ao criar uma sessão).
struct DirEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
    /// Pasta oculta (começa com ".") — escondida por padrão no seletor.
    var isHidden: Bool { name.hasPrefix(".") }
}

/// Conteúdo navegável de um diretório no Mac: caminho atual, pai (subir), subpastas.
struct DirListing: Decodable {
    let path: String
    let parent: String
    let dirs: [DirEntry]
}

// MARK: - Mensagens do WebSocket

/// Mensagens recebidas pelo canal /ws.
/// - `snapshot`: lista completa recebida ao conectar (substitui o estado local).
/// - `sessionUpdated`: uma sessão mudou (upsert na lista).
/// - `outputChunk`: um pedaço de output de uma sessão (usado na tela de detalhe),
///   já com o `kind` (user/assistant/tool/tool_result) para o transcrito estilo chat.
/// - `sessionRemoved`: uma sessão foi apagada no hub (remover da lista).
enum WSMessage: Decodable {
    case snapshot([Session])
    case sessionUpdated(Session)
    case outputChunk(sessionID: String, kind: ChunkKind, text: String)
    case sessionRemoved(sessionID: String)

    private enum CodingKeys: String, CodingKey {
        case type, sessions, session, sessionId, kind, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            let sessions = try container.decode([Session].self, forKey: .sessions)
            self = .snapshot(sessions)
        case "session_updated":
            let session = try container.decode(Session.self, forKey: .session)
            self = .sessionUpdated(session)
        case "output_chunk":
            // `session_id` vira `sessionId` via convertFromSnakeCase no decoder compartilhado.
            // O texto continua na chave `data` no wire do WS (o histórico REST usa `text`).
            let sessionID = try container.decode(String.self, forKey: .sessionId)
            let kind = try container.decode(ChunkKind.self, forKey: .kind)
            let data = try container.decode(String.self, forKey: .data)
            self = .outputChunk(sessionID: sessionID, kind: kind, text: data)
        case "session_removed":
            // `session_id` vira `sessionId` via convertFromSnakeCase no decoder compartilhado.
            let sessionID = try container.decode(String.self, forKey: .sessionId)
            self = .sessionRemoved(sessionID: sessionID)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Tipo de mensagem WS desconhecido: \(type)"
            )
        }
    }
}

// MARK: - Cutuque Board (Kanban dos agentes)

/// Um card do quadro Kanban. Espelha o `board.Task` do hub.
struct BoardTask: Identifiable, Decodable, Equatable {
    let id: String
    var title: String
    var column: String
    var group: String
    var session: String
    var type: String?
    var role: String?
    var encalhada: Bool?
    var archived: Bool?
    var description: String?
    var comments: [BoardComment]?
    var activity: [BoardActivity]?
    var startedAt: Date?
    var reviewedAt: Date?
    var endedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    var isEncalhada: Bool { encalhada ?? false }
    var commentCount: Int { comments?.count ?? 0 }
}

/// Uma observação num card.
struct BoardComment: Decodable, Equatable, Identifiable {
    let author: String
    let text: String
    let createdAt: Date?
    var id: String { "\(author)-\(createdAt?.timeIntervalSince1970 ?? 0)-\(text.hashValue)" }
}

/// Uma entrada do log de atividade (quem fez o quê e quando).
struct BoardActivity: Decodable, Equatable, Identifiable {
    let actor: String
    let action: String
    let at: Date?
    var id: String { "\(actor)-\(at?.timeIntervalSince1970 ?? 0)-\(action.hashValue)" }
}

/// Uma semana do arquivo (concluídos fechados na semana).
struct ArchivedWeek: Identifiable, Decodable, Equatable {
    let label: String            // ex.: "2026-W28"
    let start: String            // "2026-07-06"
    let end: String              // "2026-07-12"
    let tasks: [BoardTask]
    var id: String { label }
}

/// Colunas do quadro, na ordem do fluxo (igual ao hub).
enum BoardColumn: String, CaseIterable, Identifiable {
    case aFazer = "a_fazer"
    case emProgresso = "em_progresso"
    case feito
    case emRevisao = "em_revisao"
    case concluido
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aFazer:      return "A fazer"
        case .emProgresso: return "Em progresso"
        case .feito:       return "Feito"
        case .emRevisao:   return "Em revisão"
        case .concluido:   return "Concluído"
        }
    }
}

/// Cor por tipo de IA (igual ao dashboard web): Claude azul, Codex verde,
/// OpenCode roxo; cinza para tipo desconhecido.
enum AgentTypeColor {
    static func color(for type: String?) -> Color {
        switch (type ?? "").lowercased() {
        case "claude":   return Color(red: 0.18, green: 0.50, blue: 0.98) // azul
        case "codex":    return Color(red: 0.13, green: 0.77, blue: 0.37) // verde
        case "opencode": return Color(red: 0.66, green: 0.33, blue: 0.97) // roxo
        default:         return .secondary
        }
    }
}

/// Cor da tag de ambiente (grupo): paleta sortida, determinística por nome (mesma
/// do dashboard web). Tons quentes/rosados/teal/marrom — distintos de azul/verde/roxo.
enum GroupColor {
    static let palette: [Color] = [
        "#f5a623", "#f97316", "#ea580c", "#ec4899", "#db2777", "#f43f5e", "#e11d48",
        "#be123c", "#eab308", "#ca8a04", "#14b8a6", "#0d9488", "#fb7185", "#b45309",
    ].map { Color(hex: $0) }

    static func color(for name: String) -> Color {
        guard !name.isEmpty else { return .secondary }
        var h: UInt32 = 0
        for u in name.unicodeScalars { h = h &* 31 &+ u.value }
        return palette[Int(h % UInt32(palette.count))]
    }
}

extension Color {
    /// Cria uma Color a partir de "#RRGGBB".
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - Decoder compartilhado

extension JSONDecoder {
    /// Decoder usado tanto pela API REST quanto pelo WS.
    /// - snake_case → camelCase (created_at → createdAt).
    /// - datas RFC3339/ISO8601, com ou sem fração de segundos.
    static let cutuque: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = JSONDecoder.iso8601WithFraction.date(from: raw)
                ?? JSONDecoder.iso8601Plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try d.singleValueContainer(),
                debugDescription: "Data RFC3339 inválida: \(raw)"
            )
        }
        return decoder
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
