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
    // Apelidos locais das sessões (só no app).
    @ObservedObject private var namer = SessionNamesStore.shared
    // Router de deep-link vindo de uma notificação (Fase 4).
    @EnvironmentObject private var router: Router
    @State private var showingNew = false
    @State private var showingSettings = false
    @State private var showingStatus = false
    // Sessão em processo de renomear (nil = alerta fechado) + texto do apelido.
    @State private var renameTarget: Session?
    @State private var renameText = ""
    // Pilha de navegação; empurramos a sessão (criada ou deep-link) programaticamente.
    // Um único destino `for: Session.self` serve tanto o NavigationLink quanto os pushes.
    @State private var path: [Session] = []

    // Sessões que precisam de você sobem para uma seção destacada no topo.
    private var needsYou: [Session] { model.sessions.filter { $0.state == .needsYou } }
    private var others: [Session] { model.sessions.filter { $0.state != .needsYou } }

    var body: some View {
        NavigationStack(path: $path) {
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
            // Destino único para navegação por valor (NavigationLink) e por push (path).
            .navigationDestination(for: Session.self) { session in
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
                    Button {
                        showingStatus = true
                    } label: {
                        HubStatusIndicator(status: model.hubStatus)
                    }
                    // .plain preserva a cor (verde/vermelho) do ícone; sem isso o
                    // tint do botão pinta a bolinha de branco.
                    .buttonStyle(.plain)
                    .accessibilityLabel("Status do hub")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nova tarefa")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ajustes do hub")
                }
            }
            .sheet(isPresented: $showingNew) {
                NewSessionView { session in
                    // Sucesso: fecha a sheet e navega pro detalhe da sessão criada.
                    showingNew = false
                    path.append(session)
                }
            }
            .sheet(isPresented: $showingSettings) {
                HubSettingsView()
            }
            .sheet(isPresented: $showingStatus) {
                HubStatusView(sessions: model.sessions)
            }
            .alert(
                "Renomear sessão",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { session in
                TextField("Nome", text: $renameText)
                Button("Salvar") {
                    namer.setName(renameText, for: session.id)
                    renameTarget = nil
                }
                Button("Cancelar", role: .cancel) { renameTarget = nil }
            } message: { _ in
                Text("Só muda o nome aqui no app; não afeta a sessão real.")
            }
            .refreshable { await model.refresh() }
            .task {
                await model.refresh()
                model.startLiveUpdates()
                resolveDeepLink() // pode haver um push pendente antes da lista carregar
            }
            .onDisappear { model.stopLiveUpdates() }
            // Deep-link do push: quando o Router aponta uma sessão, navega até ela.
            .onChange(of: router.pendingSessionID) { _, _ in resolveDeepLink() }
            // A sessão do push pode chegar só depois da lista carregar via WS/REST.
            .onChange(of: model.sessions) { _, _ in resolveDeepLink() }
            // Ao fechar a sheet de nova tarefa, resolve um deep-link que tenha
            // chegado enquanto ela estava aberta (evita navegar por baixo dela).
            .onChange(of: showingNew) { _, isShowing in
                if !isShowing { resolveDeepLink() }
            }
        }
    }

    /// Resolve o deep-link pendente: se a sessão já está na lista, navega e limpa.
    /// Se ainda não chegou (lista carregando), mantém pendente para tentar de novo.
    /// Não navega com a sheet de nova tarefa aberta — adia até ela fechar.
    private func resolveDeepLink() {
        guard !showingNew, let id = router.pendingSessionID else { return }
        if let session = model.sessions.first(where: { $0.id == id }) {
            // Evita empurrar duas vezes o mesmo detalhe.
            if path.last?.id != session.id {
                path.append(session)
            }
            router.pendingSessionID = nil
        }
    }

    // MARK: Subviews

    private func sessionLink(_ session: Session) -> some View {
        NavigationLink(value: session) {
            SessionRow(session: session, title: namer.displayTitle(for: session))
        }
        .contextMenu {
            Button {
                renameText = namer.customName(for: session.id) ?? session.title
                renameTarget = session
            } label: {
                Label("Renomear", systemImage: "pencil")
            }
            if namer.customName(for: session.id) != nil {
                Button(role: .destructive) {
                    namer.setName("", for: session.id)
                } label: {
                    Label("Remover apelido", systemImage: "arrow.uturn.backward")
                }
            }
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
    /// Título a exibir (apelido local, se houver, senão o original).
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            // Bolinha colorida por estado.
            Circle()
                .fill(session.state.color)
                .frame(width: 12, height: 12)
                .accessibilityLabel(session.state.label)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    // Ícone de onde a sessão está rodando.
                    Image(systemName: machineSymbol(session.machine))
                    Text("\(session.machine) · \(session.agent)")
                    Text("·")
                    RelativeTime(date: session.updatedAt)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            // Prioridade de layout para o texto: o chip hugga, o texto trunca se faltar espaço.
            .layoutPriority(1)

            Spacer(minLength: 8)

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
            Text(label(relativeTo: context.date))
        }
    }

    /// "agora" para o passado/futuro recente (evita "em 0 seg."); relativo caso contrário.
    private func label(relativeTo now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 10 { return "agora" }
        return Self.formatter.localizedString(for: date, relativeTo: now)
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
