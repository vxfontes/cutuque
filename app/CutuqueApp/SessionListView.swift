import SwiftUI

// MARK: - ViewModel

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hubStatus: HealthStatus = .unknown

    private let api = APIClient()
    private let health = HealthClient()
    private var liveTask: Task<Void, Never>?

    // MARK: Carga inicial e pull-to-refresh

    /// Recarrega a lista via REST e checa a saúde do hub.
    func refresh() async {
        async let statusResult = health.check()
        do {
            sessions = sortedByRecent(try await api.sessions())
        } catch {
            // Falha na REST não derruba a UI; o indicador de saúde reflete o estado do hub.
        }
        hubStatus = await statusResult
    }

    // MARK: Atualização ao vivo (WebSocket)

    /// Inicia o consumo do stream do /ws. Idempotente: não abre dois streams.
    func startLiveUpdates() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            for await message in self.api.liveUpdates() {
                switch message {
                case .snapshot(let all):
                    // Snapshot substitui todo o estado local.
                    self.sessions = self.sortedByRecent(all)
                case .sessionUpdated(let session):
                    // Upsert: substitui a existente ou insere a nova.
                    self.upsert(session)
                case .outputChunk:
                    // A lista não exibe output; chunks são tratados na tela de detalhe.
                    break
                }
                // Qualquer mensagem recebida confirma que o hub está online.
                self.hubStatus = .online
            }
        }
    }

    /// Encerra o stream ao vivo (ao sair da tela).
    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: Helpers

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions = sortedByRecent(sessions)
    }

    /// Mais recentes primeiro (por updated_at).
    private func sortedByRecent(_ list: [Session]) -> [Session] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Lista de sessões

struct SessionListView: View {
    @StateObject private var model = SessionListViewModel()

    var body: some View {
        List(model.sessions) { session in
            NavigationLink(value: session) {
                SessionRow(session: session)
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: Session.self) { session in
            SessionDetailView(session: session)
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("Nenhuma sessão", systemImage: "terminal")
            }
        }
        .navigationTitle("Sessões")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HubStatusIndicator(status: model.hubStatus)
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            model.startLiveUpdates()
        }
        .onDisappear { model.stopLiveUpdates() }
    }
}

// MARK: - Linha da lista

private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            // Bolinha colorida por estado.
            Circle()
                .fill(session.state.color)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body)
                Text("\(session.machine) · \(session.agent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(session.state.label)
                .font(.caption)
                .foregroundStyle(session.state.color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Indicador de saúde do hub (toolbar)

private struct HubStatusIndicator: View {
    let status: HealthStatus

    var body: some View {
        switch status {
        case .unknown:
            Label("verificando", systemImage: "circle.dotted")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        case .online:
            Label("hub online", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        case .offline:
            Label("hub offline", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
        }
    }
}
