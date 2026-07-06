import SwiftUI
import UIKit

// MARK: - ViewModel

/// Uma sessão que está rodando AGORA numa máquina (poll do /machines/{m}/live).
struct LiveEntry: Identifiable, Equatable {
    let machine: String
    let session: DiscoveredSession
    var id: String { session.id }
}

/// Alvo de "encerrar server" (kill-server), para a confirmação.
struct ServerKill: Identifiable, Equatable {
    let machine: String
    let socket: String
    let name: String
    var id: String { socket }
}

@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var hubStatus: HealthStatus = .unknown
    /// Sessões vivas no Mac (rodando em tempo real), atualizadas por polling.
    @Published var liveSessions: [LiveEntry] = [] {
        didSet {
            // Live Activity agregada: total ao vivo + quantas rodando agora
            // (panes de tmux nunca são subagentes, então já ficam de fora).
            if #available(iOS 16.1, *) {
                let live = liveSessions.count
                let active = liveSessions.filter { $0.session.state == "running" }.count
                LiveActivityManager.shared.update(live: live, active: active)
            }
        }
    }
    /// Falso até a 1ª carga (REST) terminar — evita a home piscar "vazio" e
    /// então "brotar" sessões.
    @Published var didInitialLoad = false

    private let api = APIClient()
    private let health = HealthClient()
    private var liveTask: Task<Void, Never>?
    private var livePollTask: Task<Void, Never>?
    // Resiliência do poll de vivas: cacheia as máquinas (falha de fetch não zera
    // o "Ao vivo") e exige 2 leituras vazias seguidas antes de limpar (evita o
    // "some e volta" de um hiccup transitório).
    private var cachedMachines: [String] = []
    private var emptyLiveStreak = 0

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
        didInitialLoad = true
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
                case .sessionRemoved(let id):
                    // Sessão apagada no hub: some da lista (com animação).
                    withAnimation(.snappy) {
                        self.sessions.removeAll { $0.id == id }
                    }
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

    // MARK: Sessões vivas no Mac (polling)

    /// Começa a pollar as sessões vivas de todas as máquinas a cada ~15s.
    /// Idempotente. Uma passada roda já no início (sem esperar o 1º sleep).
    func startLivePolling() {
        guard livePollTask == nil else { return }
        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLive()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopLivePolling() {
        livePollTask?.cancel()
        livePollTask = nil
    }

    /// Uma passada de descoberta de vivas: para cada máquina, lista os panes do
    /// tmux rodando claude (as sessões controláveis ao vivo — send-keys/mirror).
    func refreshLive() async {
        // Máquinas com cache: se o fetch falhar (hiccup), reusa as últimas — assim
        // uma falha transitória NÃO zera o "Ao vivo".
        let machines = (try? await api.targets()).flatMap { $0.isEmpty ? nil : $0 } ?? cachedMachines
        guard !machines.isEmpty else { return } // sem como consultar → mantém o estado
        cachedMachines = machines

        var all: [LiveEntry] = []
        for machine in machines {
            let panes = await api.tmuxList(machine: machine)
            all.append(contentsOf: panes.map { LiveEntry(machine: machine, session: $0) })
        }

        // Veio vazio mas tínhamos sessões? Pode ser hiccup do SSH — só limpa após
        // 2 leituras vazias seguidas (mata o "some e volta").
        if all.isEmpty && !liveSessions.isEmpty {
            emptyLiveStreak += 1
            if emptyLiveStreak < 2 { return }
        } else {
            emptyLiveStreak = 0
        }

        // Só re-anima quando o CONJUNTO de panes muda; mudança só de estado (cor)
        // aplica sem animar a lista inteira → menos piscada.
        if all.map(\.id) != liveSessions.map(\.id) {
            withAnimation(.snappy) { liveSessions = all }
        } else {
            liveSessions = all
        }
    }

    // MARK: Apagar sessão

    /// Apaga uma sessão: remove da lista na hora (otimista) e dispara o DELETE
    /// no hub. Falha do hub não reverte — o WS `session_removed` (ou o próximo
    /// refresh) reconcilia o estado se necessário.
    func delete(_ session: Session) {
        withAnimation(.snappy) {
            sessions.removeAll { $0.id == session.id }
        }
        Task { try? await api.deleteSession(id: session.id) }
    }

    /// Marca uma sessão como CONCLUÍDA: tira de needs_you (não apaga). Some da
    /// seção "Precisa de você" na hora; o hub marca done e o WS reconcilia. Não
    /// vira dismissed, então a sessão pode voltar a te avisar se precisar.
    func resolve(_ session: Session) {
        withAnimation(.snappy) {
            sessions.removeAll { $0.id == session.id }
        }
        Task { try? await api.resolve(sessionID: session.id) }
    }

    /// Encerra o servidor tmux inteiro (kill-server): fecha todos os panes
    /// daquele socket. Remove as entradas vivas na hora; o próximo poll reconcilia.
    func killServer(machine: String, socket: String) {
        withAnimation(.snappy) {
            liveSessions.removeAll { $0.id.hasPrefix(socket + "\t") }
        }
        Task {
            try? await api.tmuxKillServer(machine: machine, socket: socket)
            await refreshLive()
        }
    }

    /// Apaga (dismiss) todas as sessões concluídas (done/error) de uma vez —
    /// limpa a seção "Concluídas". Otimista + DELETE por sessão no hub.
    func clearConcluded() {
        let ids = sessions.filter { $0.state == .done || $0.state == .error }.map(\.id)
        withAnimation(.snappy) {
            sessions.removeAll { ids.contains($0.id) }
        }
        Task { for id in ids { try? await api.deleteSession(id: id) } }
    }

    /// Apaga (dismiss) todos os subagentes (externos sem pane) de uma vez.
    func clearSubagents() {
        let ids = sessions.filter { $0.isExternal && $0.tmuxTarget == nil }.map(\.id)
        withAnimation(.snappy) {
            sessions.removeAll { ids.contains($0.id) }
        }
        Task { for id in ids { try? await api.deleteSession(id: id) } }
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
    @State private var showingDiscover = false
    @State private var showingSettings = false
    @State private var showingStatus = false
    @State private var showingHistory = false
    // Sessão em processo de renomear (nil = alerta fechado) + texto do apelido.
    @State private var renameTarget: Session?
    @State private var renameText = ""
    // Pilha de navegação; empurramos a sessão (criada ou deep-link) programaticamente.
    // Um único destino `for: Session.self` serve tanto o NavigationLink quanto os pushes.
    @State private var path: [Session] = []
    // Pane do tmux aberto no espelho de terminal (nil = fechado).
    @State private var selectedLive: LiveEntry?
    // Server tmux a encerrar (confirmação de kill-server) e estado das concluídas.
    @State private var serverToKill: ServerKill?
    @State private var confirmingClear = false
    @State private var confirmingClearSubagents = false
    @State private var concludedExpanded = false
    @State private var subagentsExpanded = false
    // Tema de cor escolhido nos ajustes — o "ao vivo" (rodando) segue ele.
    @AppStorage(AppThemeKeys.accent) private var accentRaw = AppAccent.blue.rawValue
    private var accentColor: Color { (AppAccent(rawValue: accentRaw) ?? .blue).color }

    // Alvos tmux (compostos socket\tpane) que estão vivos agora.
    private var livePaneIDs: Set<String> { Set(model.liveSessions.map(\.id)) }
    // Panes das sessões que precisam de você (pra não duplicar em "Ao vivo").
    private var needsYouPaneIDs: Set<String> { Set(needsYou.compactMap(\.tmuxTarget)) }

    // Subagente / sessão "solta": externa (de hook) e SEM pane de tmux — não dá
    // pra interagir ao vivo (sem terminal pra espelhar). São os subagentes do
    // maestri e afins; ficam arquivados na seção "Subagentes" (recap sob demanda),
    // fora das seções principais, para não inundar a home com títulos repetidos.
    private func isSubagent(_ s: Session) -> Bool { s.isExternal && s.tmuxTarget == nil }
    private var subagents: [Session] { model.sessions.filter { isSubagent($0) } }

    // "Precisa de você": needs_you acionável (tem pane de tmux OU foi lançada pelo
    // app). Subagentes sem pane não entram aqui (vão pra "Subagentes").
    private var needsYou: [Session] { model.sessions.filter { $0.state == .needsYou && !isSubagent($0) } }
    // "Ao vivo no Mac": panes do tmux vivos que NÃO estão em needs_you (esses já
    // aparecem em "Precisa de você" e abrem o terminal ao tocar).
    private var liveNotTracked: [LiveEntry] {
        model.liveSessions.filter { !needsYouPaneIDs.contains($0.id) }
    }
    // "Sessões": registry que não é needs_you, não é subagente e NÃO é uma sessão
    // viva do tmux (dedup: a viva aparece em "Ao vivo"/"Precisa de você").
    private var others: [Session] {
        model.sessions.filter { s in
            s.state != .needsYou && !isSubagent(s) && !(s.tmuxTarget.map { livePaneIDs.contains($0) } ?? false)
        }
    }
    // "Sessões" ativas (rodando/ociosas) ficam em destaque; concluídas (done/error)
    // vão para a seção recolhível "Concluídas".
    private var activeOthers: [Session] { others.filter { $0.state != .done && $0.state != .error } }
    private var concludedOthers: [Session] { others.filter { $0.state == .done || $0.state == .error } }

    // "Ao vivo" agrupado por servidor tmux (nome = basename do socket do id
    // composto "<socket>\t<pane>"), ordenado por nome — para uma seção por server.
    private var liveByServer: [(server: String, socket: String, entries: [LiveEntry])] {
        let groups = Dictionary(grouping: liveNotTracked) { Self.socket(of: $0.id) }
        return groups.keys.sorted().map { sock in
            (server: Self.serverName(sock), socket: sock, entries: groups[sock] ?? [])
        }
    }
    /// Socket (parte antes do TAB) de um id composto de pane.
    static func socket(of id: String) -> String {
        String(id.split(separator: "\t", maxSplits: 1).first ?? "")
    }
    /// Nome legível do server = último componente do socket (ex.: "main", "teste").
    static func serverName(_ socket: String) -> String {
        (socket as NSString).lastPathComponent
    }

    // "Ao vivo no Mac": uma seção por servidor tmux, com ação de encerrar server.
    @ViewBuilder private var liveServerSections: some View {
        ForEach(liveByServer, id: \.socket) { group in
            Section {
                ForEach(group.entries) { liveRow($0) }
            } header: {
                HStack {
                    Label("Ao vivo · \(group.server)", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(accentColor)
                        .textCase(nil)
                    Spacer()
                    Menu {
                        Button(role: .destructive) {
                            serverToKill = ServerKill(
                                machine: group.entries.first?.machine ?? "macbook",
                                socket: group.socket, name: group.server)
                        } label: {
                            Label("Encerrar server", systemImage: "xmark.octagon")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Ações do server \(group.server)")
                }
            }
        }
    }

    @ViewBuilder private var needsYouSection: some View {
        if !needsYou.isEmpty {
            Section {
                ForEach(needsYou) { needsYouRow($0) }
            } header: {
                Label("Precisa de você", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textCase(nil)
            } footer: {
                Text("Toque para responder — as do tmux abrem o terminal ao vivo.")
            }
        }
    }

    @ViewBuilder private var activeSection: some View {
        if !activeOthers.isEmpty {
            Section("Sessões") {
                ForEach(activeOthers) { sessionLink($0) }
            }
        }
    }

    @ViewBuilder private var concludedSection: some View {
        if !concludedOthers.isEmpty {
            Section {
                DisclosureGroup("Concluídas (\(concludedOthers.count))", isExpanded: $concludedExpanded) {
                    ForEach(concludedOthers) { sessionLink($0) }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Limpar todas", systemImage: "trash")
                    }
                }
            }
        }
    }

    // "Subagentes": sessões externas sem pane, arquivadas e recolhidas. Toque
    // abre o recap da conversa (sem interação ao vivo). Não cutucam. "Limpar
    // todos" apaga de uma vez (dismiss).
    @ViewBuilder private var subagentsSection: some View {
        if !subagents.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $subagentsExpanded) {
                    ForEach(subagents) { sessionLink($0) }
                    Button(role: .destructive) {
                        confirmingClearSubagents = true
                    } label: {
                        Label("Limpar todos", systemImage: "trash")
                    }
                } label: {
                    Label("Subagentes (\(subagents.count))", systemImage: "square.stack.3d.up")
                        .textCase(nil)
                }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                liveServerSections
                needsYouSection
                activeSection
                concludedSection
                subagentsSection
            }
            .listStyle(.insetGrouped)
            // Destino único para navegação por valor (NavigationLink) e por push (path).
            .navigationDestination(for: Session.self) { session in
                SessionDetailView(session: session)
            }
            .overlay {
                if !model.didInitialLoad {
                    ProgressView().controlSize(.large)
                } else if model.sessions.isEmpty && liveNotTracked.isEmpty {
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
                    Menu {
                        Button {
                            showingNew = true
                        } label: {
                            Label("Nova tarefa", systemImage: "plus")
                        }
                        Button {
                            showingDiscover = true
                        } label: {
                            Label("Continuar sessão do Mac", systemImage: "macbook.and.iphone")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nova tarefa ou continuar sessão")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Histórico de sessões")
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
            .sheet(isPresented: $showingDiscover) {
                DiscoverSessionsView { session in
                    // Adotou: fecha a sheet e navega pro detalhe (continua a conversa).
                    showingDiscover = false
                    if path.last?.id != session.id {
                        path.append(session)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                HubSettingsView()
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView()
            }
            .sheet(item: $selectedLive) { entry in
                NavigationStack {
                    LiveDetailView(entry: entry)
                }
            }
            .sheet(isPresented: $showingStatus) {
                HubStatusView(sessions: model.sessions, live: model.liveSessions)
            }
            // Encerrar server (kill-server) — destrutivo, confirma antes.
            .confirmationDialog(
                "Encerrar o server \(serverToKill?.name ?? "")?",
                isPresented: Binding(get: { serverToKill != nil }, set: { if !$0 { serverToKill = nil } }),
                presenting: serverToKill
            ) { target in
                Button("Encerrar server", role: .destructive) {
                    model.killServer(machine: target.machine, socket: target.socket)
                }
                Button("Cancelar", role: .cancel) {}
            } message: { target in
                Text("Fecha TODOS os panes/Claudes do server \(target.name) de uma vez.")
            }
            // Limpar concluídas — destrutivo, confirma antes.
            .confirmationDialog(
                "Limpar as concluídas?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Limpar \(concludedOthers.count)", role: .destructive) {
                    model.clearConcluded()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Apaga da lista todas as sessões concluídas (não afeta o transcript no Mac).")
            }
            .confirmationDialog(
                "Limpar os subagentes?",
                isPresented: $confirmingClearSubagents,
                titleVisibility: .visible
            ) {
                Button("Limpar \(subagents.count)", role: .destructive) {
                    model.clearSubagents()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Apaga da lista todos os subagentes (não afeta o transcript no Mac).")
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
            .refreshable {
                await model.refresh()
                await model.refreshLive()
            }
            .task {
                await model.refresh()
                model.startLiveUpdates()
                model.startLivePolling()
                resolveDeepLink() // pode haver um push pendente antes da lista carregar
            }
            .onDisappear {
                model.stopLiveUpdates()
                model.stopLivePolling()
            }
            // Deep-link do push: quando o Router aponta uma sessão, navega até ela.
            .onChange(of: router.pendingSessionID) { _, _ in resolveDeepLink() }
            // A sessão do push pode chegar só depois da lista carregar via WS/REST.
            .onChange(of: model.sessions) { _, _ in resolveDeepLink() }
            // Ao fechar a sheet de nova tarefa, resolve um deep-link que tenha
            // chegado enquanto ela estava aberta (evita navegar por baixo dela).
            .onChange(of: showingNew) { _, isShowing in
                if !isShowing { resolveDeepLink() }
            }
            .onChange(of: showingDiscover) { _, isShowing in
                if !isShowing { resolveDeepLink() }
            }
        }
    }

    /// Resolve o deep-link pendente: se a sessão já está na lista, navega e limpa.
    /// Se ainda não chegou (lista carregando), mantém pendente para tentar de novo.
    /// Não navega com a sheet de nova tarefa aberta — adia até ela fechar.
    private func resolveDeepLink() {
        guard !showingNew, !showingDiscover, let id = router.pendingSessionID else { return }
        if let session = model.sessions.first(where: { $0.id == id }) {
            if let target = session.tmuxTarget {
                // Sessão do tmux: o push abre o TERMINAL AO VIVO correspondente,
                // não o detalhe (que fica vazio para sessões externas — bug antigo
                // de "cair numa página sem mensagem nenhuma").
                selectedLive = LiveEntry(
                    machine: session.machine,
                    session: DiscoveredSession(id: target, cwd: session.cwd ?? "", title: namer.displayTitle(for: session))
                )
            } else if path.last?.id != session.id {
                // Sessão orquestrada pelo app (sem tmux): abre o detalhe/chat normal.
                path.append(session)
            }
            router.pendingSessionID = nil
        }
    }

    // MARK: Subviews

    /// Linha de uma sessão viva no Mac (pane do tmux): toca → abre o espelho do
    /// terminal ao vivo (ver a tela + digitar de verdade nela).
    /// Cor da linha ao vivo: "rodando" segue o TEMA (accent); os demais estados
    /// mantêm a cor semântica (verde concluiu / laranja espera).
    private func liveColor(_ entry: LiveEntry) -> Color {
        let s = liveState(entry)
        return s == .running ? accentColor : s.color
    }

    private func liveRow(_ entry: LiveEntry) -> some View {
        let color = liveColor(entry)
        return Button {
            selectedLive = entry
        } label: {
            HStack(spacing: 12) {
                // Cor do tema enquanto roda, verde quando concluiu.
                LivePulse(color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.session.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: machineSymbol(entry.machine))
                        Text(entry.session.folderName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "terminal").foregroundStyle(color)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Estado da sessão viva. Fonte da verdade é o estado LIDO DO TERMINAL pelo
    /// hub (sobrevive a restart do hub, reflete a realidade): running→azul,
    /// idle/concluído→verde, waiting→laranja. Só cai na correlação com o registry
    /// se o hub for antigo e não mandar o estado do pane.
    private func liveState(_ entry: LiveEntry) -> SessionState {
        switch entry.session.state {
        case "running": return .running
        case "idle", "done": return .done
        case "waiting": return .needsYou
        default:
            return model.sessions.first(where: { $0.tmuxTarget == entry.id })?.state ?? .running
        }
    }

    /// Linha de uma sessão em needs_you. Se ela roda no tmux (tem pane), tocar
    /// abre a sessão AO VIVO correspondente (respondes a múltipla escolha no
    /// terminal); senão, o detalhe normal.
    private func needsYouRow(_ session: Session) -> some View {
        Group {
            if let target = session.tmuxTarget {
                Button {
                    selectedLive = LiveEntry(
                        machine: session.machine,
                        session: DiscoveredSession(id: target, cwd: session.cwd ?? "", title: namer.displayTitle(for: session))
                    )
                } label: {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: session) {
                    SessionRow(session: session, title: namer.displayTitle(for: session))
                }
            }
        }
        // Arrastar pro lado: concluir (tira de needs_you, sem apagar) ou apagar.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { model.resolve(session) } label: {
                Label("Concluir", systemImage: "checkmark")
            }
            .tint(.green)
            Button(role: .destructive) { model.delete(session) } label: {
                Label("Apagar", systemImage: "trash")
            }
        }
    }

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
        // Swipe da direita: apagar a sessão (otimista + DELETE no hub).
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.delete(session)
            } label: {
                Label("Apagar", systemImage: "trash")
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

// MARK: - Pulso "ao vivo" (bolinha verde pulsante)

private struct LivePulse: View {
    /// Cor do pulso, dirigida pelo estado da sessão (azul rodando, verde concluído).
    var color: Color = .blue
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(on ? 2.2 : 1)
                    .opacity(on ? 0 : 0.8)
            )
            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
            .accessibilityLabel("ao vivo")
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
