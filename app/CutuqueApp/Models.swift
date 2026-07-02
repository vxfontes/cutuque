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

// MARK: - Sessão

/// Uma sessão de agente reportada pelo hub.
/// Chaves em snake_case são resolvidas via `convertFromSnakeCase` no decoder compartilhado.
struct Session: Codable, Identifiable, Equatable {
    let id: String
    let machine: String
    let agent: String
    let title: String
    let state: SessionState
    let createdAt: Date
    let updatedAt: Date
}

// MARK: - Mensagens do WebSocket

/// Mensagens recebidas pelo canal /ws.
/// - `snapshot`: lista completa recebida ao conectar (substitui o estado local).
/// - `sessionUpdated`: uma sessão mudou (upsert na lista).
enum WSMessage: Decodable {
    case snapshot([Session])
    case sessionUpdated(Session)

    private enum CodingKeys: String, CodingKey {
        case type, sessions, session
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
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Tipo de mensagem WS desconhecido: \(type)"
            )
        }
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
