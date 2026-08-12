import Foundation

/// Para quem vai cada mensagem do `/ws`. Função pura, separada da conexão, para
/// ter teste sem hub no ar.
enum LiveHubRouting {
    static func destinatarios(de mensagem: WSMessage, inscritos: [String]) -> [String] {
        switch mensagem {
        case .sessionUpdated(let s):
            return inscritos.filter { $0 == s.id }
        case .outputChunk(let sessionID, _, _):
            return inscritos.filter { $0 == sessionID }
        default:
            // Snapshot, sessionRemoved e qualquer tipo novo vão para todos; quem
            // recebe filtra. Descartar o desconhecido aqui criaria um bug sem
            // sintoma.
            return inscritos
        }
    }
}

/// Uma conexão ao `/ws` para todas as abas abertas.
///
/// Antes de 08/2026 cada `SessionDetailViewModel` abria a sua e filtrava do lado
/// do cliente. Com o teto de 6 painéis montados (D3) isso viraram seis conexões
/// fazendo o mesmo trabalho, cada uma com backoff próprio. O hub aqui recebe uma
/// vez e distribui — a filtragem que estava em cada ViewModel virou
/// `LiveHubRouting`, testável.
@MainActor
final class LiveHub: ObservableObject {
    private let api: APIClient
    // Por sessão, um dicionário de continuations chaveado por token de
    // assinatura — não uma continuation só. Chavear direto pelo sessionID
    // (versão de 12/08/2026, achado da revisão) fazia a segunda assinatura da
    // mesma sessão sobrescrever a primeira em silêncio, deixando-a órfã: sem
    // .finish(), sem mensagens, sem erro. O modelo de abas (G1) não duplica
    // aba de sessão, mas o LiveHub não pode depender dessa invariante alheia.
    private var inscritos: [String: [UUID: AsyncStream<WSMessage>.Continuation]] = [:]
    private var upstream: Task<Void, Never>?

    init(api: APIClient) { self.api = api }

    /// Assina as mensagens de uma sessão. A conexão sobe na primeira assinatura
    /// e desce quando a última sai — nada de socket aberto sem ninguém ouvindo.
    func inscrever(sessionID: String) -> AsyncStream<WSMessage> {
        AsyncStream { continuation in
            let token = UUID()
            inscritos[sessionID, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.cancelar(sessionID: sessionID, token: token) }
            }
            garantirConexao()
        }
    }

    private func cancelar(sessionID: String, token: UUID) {
        inscritos[sessionID]?[token]?.finish()
        inscritos[sessionID]?[token] = nil
        if inscritos[sessionID]?.isEmpty == true { inscritos[sessionID] = nil }
        if inscritos.isEmpty {
            upstream?.cancel()
            upstream = nil
        }
    }

    private func garantirConexao() {
        guard upstream == nil else { return }
        upstream = Task { [weak self] in
            guard let stream = self?.api.liveUpdates() else { return }
            for await mensagem in stream {
                guard let self else { break }
                let destinos = LiveHubRouting.destinatarios(de: mensagem,
                                                           inscritos: Array(self.inscritos.keys))
                for id in destinos { self.inscritos[id]?.values.forEach { $0.yield(mensagem) } }
            }
        }
    }
}
