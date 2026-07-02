import SwiftUI
import UIKit

// MARK: - ViewModel

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hubStatus: HealthStatus = .unknown

    private let api = APIClient()
    private let health = HealthClient()
    private var liveTask: Task<Void, Never>?

    // Haptics locais: "gostinho do cutucão" antes do push da Fase 4.
    private let haptics = UINotificationFeedbackGenerator()
    private var lastHapticAt: Date?

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
            // Não reter self pela vida do loop: desembrulha a cada iteração e
            // encerra quando o ViewModel morrer (evita ciclo self→task→self
            // que vazaria a conexão WS — review F2, achado #2).
            guard let stream = self?.api.liveUpdates() else { return }
            for await message in stream {
                guard let self else { break }
                switch message {
                case .snapshot(let all):
                    // Snapshot substitui todo o estado local (sem haptic — carga inicial).
                    withAnimation(.snappy) {
                        self.sessions = self.sortedByRecent(all)
                    }
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
            let previous = sessions[index].state
            // Só dispara haptic em transição REAL de estado (não em re-render).
            if previous != session.state {
                fireHaptic(for: session.state)
            }
            withAnimation(.snappy) { sessions[index] = session }
        } else {
            withAnimation(.snappy) { sessions.append(session) }
        }
        withAnimation(.snappy) { sessions = sortedByRecent(sessions) }
    }

    /// Haptic conforme o novo estado, com debounce de no máx. 1 por segundo.
    private func fireHaptic(for state: SessionState) {
        let now = Date()
        if let last = lastHapticAt, now.timeIntervalSince(last) < 1 { return }
        let type: UINotificationFeedbackGenerator.FeedbackType
        switch state {
        case .needsYou: type = .warning
        case .done:     type = .success
        case .error:    type = .error
        default:        return // running/idle não vibram
        }
        haptics.prepare()
        haptics.notificationOccurred(type)
        lastHapticAt = now
    }

    /// Mais recentes primeiro (por updated_at).
    private func sortedByRecent(_ list: [Session]) -> [Session] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Lista de sessões

struct SessionListView: View {
    @StateObject private var model = SessionListViewModel()
    @State private var showingNew = false
    @State private var createdSession: Session?

    // Sessões que precisam de você sobem para uma seção destacada no topo.
    private var needsYou: [Session] { model.sessions.filter { $0.state == .needsYou } }
    private var others: [Session] { model.sessions.filter { $0.state != .needsYou } }

    var body: some View {
        List {
            if !needsYou.isEmpty {
                Section {
                    ForEach(needsYou) { sessionLink($0) }
                } header: {
                    Label("Precisa de você", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textCase(nil)
                }
            }
            if !others.isEmpty {
                Section("Sessões") {
                    ForEach(others) { sessionLink($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Session.self) { session in
            SessionDetailView(session: session)
        }
        // Navegação programática para a sessão recém-criada.
        .navigationDestination(item: $createdSession) { session in
            SessionDetailView(session: session)
        }
        .overlay {
            if model.sessions.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Sessões")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HubStatusIndicator(status: model.hubStatus)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nova tarefa")
            }
        }
        .sheet(isPresented: $showingNew) {
            NewSessionView { session in
                // Sucesso: fecha a sheet e navega pro detalhe da sessão criada.
                showingNew = false
                createdSession = session
            }
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            model.startLiveUpdates()
        }
        .onDisappear { model.stopLiveUpdates() }
    }

    // MARK: Subviews

    private func sessionLink(_ session: Session) -> some View {
        NavigationLink(value: session) {
            SessionRow(session: session)
        }
    }

    // Empty state convidativo: ícone + texto + atalho para nova tarefa.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nenhuma sessão", systemImage: "terminal")
        } description: {
            Text("Dispare uma tarefa para acompanhar seus agentes por aqui.")
        } actions: {
            Button {
                showingNew = true
            } label: {
                Label("Nova tarefa", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
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
                .accessibilityLabel(session.state.label)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body)
                HStack(spacing: 4) {
                    Text("\(session.machine) · \(session.agent)")
                    Text("·")
                    RelativeTime(date: session.updatedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            StateChip(state: session.state)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Timestamp relativo (atualiza sozinho a cada 30s)

private struct RelativeTime: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated // ex.: "há 2 min"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.formatter.localizedString(for: date, relativeTo: context.date))
        }
    }
}

// MARK: - Indicador de saúde do hub (toolbar)

private struct HubStatusIndicator: View {
    let status: HealthStatus

    var body: some View {
        icon
            .labelStyle(.iconOnly)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .unknown:
            Label("verificando", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .online:
            Label("hub online", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .offline:
            Label("hub offline", systemImage: "circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityText: String {
        switch status {
        case .unknown: return "verificando o hub"
        case .online:  return "hub online"
        case .offline: return "hub offline"
        }
    }
}
