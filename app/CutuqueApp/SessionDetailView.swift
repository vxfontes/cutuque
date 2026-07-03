import SwiftUI

// MARK: - ViewModel

@MainActor
final class SessionDetailViewModel: ObservableObject {
    /// Sessão exibida; o estado é atualizado ao vivo via `session_updated`.
    @Published var session: Session
    /// Linhas de output acumuladas (histórico + chunks ao vivo).
    @Published var lines: [String] = []
    /// Uma ação (aprovar/negar/enviar) está em andamento — desabilita botões.
    @Published var actionInProgress = false
    /// Aviso transitório para a UI (ex.: estado mudou no 409).
    @Published var notice: String?

    private let api = APIClient()
    private var liveTask: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    // MARK: Carga inicial + stream ao vivo

    /// Carrega o histórico de output e assina o stream ao vivo.
    func start() async {
        // Histórico via REST (pode vir vazio se o adapter ainda não implementou o endpoint).
        if let history = try? await api.output(sessionID: session.id) {
            lines = history
        }
        startLiveUpdates()
    }

    /// Assina o /ws e reage a mudanças de estado e a chunks da sessão aberta.
    private func startLiveUpdates() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            // Não reter self pela vida do loop: desembrulha a cada iteração e
            // encerra quando o ViewModel morrer (evita ciclo self→task→self
            // que vazaria a conexão WS — review F2, achado #2).
            guard let stream = self?.api.liveUpdates() else { return }
            for await message in stream {
                guard let self else { break }
                switch message {
                case .sessionUpdated(let updated) where updated.id == self.session.id:
                    // Só interessa a sessão aberta; atualiza a badge de estado.
                    self.session = updated
                case .outputChunk(let sessionID, let data) where sessionID == self.session.id:
                    // Appenda apenas chunks da sessão aberta, espelhando o teto
                    // de 200 do hub para não crescer sem limite (review F2, #6).
                    self.lines.append(data)
                    if self.lines.count > 200 {
                        self.lines.removeFirst(self.lines.count - 200)
                    }
                case .snapshot(let all):
                    // Um snapshot pode trazer estado mais recente da sessão aberta.
                    if let mine = all.first(where: { $0.id == self.session.id }) {
                        self.session = mine
                    }
                default:
                    break
                }
            }
        }
    }

    /// Encerra o stream ao sair da tela.
    func stop() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: Ações (aprovar / negar / responder)

    func approve() async {
        await runAction { try await self.api.approve(sessionID: self.session.id) }
    }

    func deny() async {
        await runAction { try await self.api.deny(sessionID: self.session.id) }
    }

    /// Envia texto livre ao agente. Retorna `true` se enviou (para limpar o campo).
    func sendInput(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await runAction { try await self.api.sendInput(sessionID: self.session.id, text: trimmed) }
    }

    /// Lança uma NOVA sessão na mesma máquina desta (usado quando esta já
    /// encerrou — done/error/idle — e não há processo vivo pra responder).
    /// Devolve a sessão criada (para o chamador navegar até ela), ou nil em falha.
    func launchNew(_ text: String) async -> Session? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        actionInProgress = true
        defer { actionInProgress = false }
        do {
            return try await api.createSession(machine: session.machine, agent: session.agent, prompt: trimmed)
        } catch let CutuqueError.server(status, message) {
            notice = status == 504
                ? "o agente demorou a responder — confira a lista, a sessão pode aparecer"
                : message
            return nil
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    /// Executa uma ação com loading; no 409 recarrega a sessão e avisa "o estado mudou".
    @discardableResult
    private func runAction(_ perform: @escaping () async throws -> Void) async -> Bool {
        actionInProgress = true
        defer { actionInProgress = false }
        do {
            try await perform()
            return true
        } catch CutuqueError.staleState {
            await reloadSession()
            notice = "o estado mudou"
            return false
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    /// Sem GET de sessão única no contrato: recarrega a lista e recupera a sessão aberta.
    private func reloadSession() async {
        if let list = try? await api.sessions(),
           let mine = list.first(where: { $0.id == session.id }) {
            session = mine
        }
    }
}

// MARK: - Tela de detalhe

struct SessionDetailView: View {
    @StateObject private var model: SessionDetailViewModel
    @ObservedObject private var namer = SessionNamesStore.shared
    // Router p/ navegar ao detalhe da nova sessão ao relançar de uma encerrada.
    @EnvironmentObject private var router: Router
    @State private var draft = ""
    @State private var showScrollToBottom = false
    @State private var renaming = false
    @State private var renameText = ""

    init(session: Session) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
    }

    /// Título a exibir (apelido local, se houver, senão o original).
    private var displayTitle: String { namer.displayTitle(for: model.session) }

    /// Texto do pedido de permissão, se houver, quando a sessão precisa de você.
    private var permissionPrompt: String? {
        guard model.session.state == .needsYou,
              let prompt = model.session.pendingPrompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Card de permissão acima do terminal (invariante docs/04: sempre exibe o texto).
            if let prompt = permissionPrompt {
                permissionCard(prompt)
            }
            outputTerminal
            // Barra de digitação SEMPRE visível. Em sessão viva, o texto responde
            // ao agente em andamento; em sessão encerrada (sem processo vivo), o
            // texto lança uma nova tarefa na mesma máquina (relançar).
            interactionBar
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameText = namer.customName(for: model.session.id) ?? model.session.title
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Renomear sessão")
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        .alert("Renomear sessão", isPresented: $renaming) {
            TextField("Nome", text: $renameText)
            Button("Salvar") { namer.setName(renameText, for: model.session.id) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Só muda o nome aqui no app; não afeta a sessão real.")
        }
        .alert(
            "Aviso",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            presenting: model.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice)
        }
    }

    // MARK: Card de permissão (needs_you com pending_prompt)

    private func permissionCard(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Precisa de você", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            // Texto COMPLETO do pedido — nunca aprovar às cegas.
            Text(prompt)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button {
                    Task { await model.approve() }
                } label: {
                    Label("Aprovar", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .accessibilityLabel("Aprovar o pedido")

                Button {
                    Task { await model.deny() }
                } label: {
                    Label("Negar", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .accessibilityLabel("Negar o pedido")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.actionInProgress)
            .overlay {
                if model.actionInProgress {
                    ProgressView()
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    // MARK: Barra de interação (responder OU relançar, conforme o estado)

    /// Viva (rodando/precisa de você): há processo pra receber o texto.
    private var isLive: Bool {
        model.session.state == .running || model.session.state == .needsYou
    }

    private var interactionBar: some View {
        HStack(spacing: 8) {
            TextField(
                isLive ? "responder ao agente..." : "continuar a conversa...",
                text: $draft, axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)

            Button {
                let text = draft
                Task {
                    // Sempre a MESMA sessão: viva → responde ao agente em
                    // andamento; encerrada → o hub retoma a conversa (claude
                    // --resume) e a resposta chega nesta mesma tela via WS.
                    if await model.sendInput(text) { draft = "" }
                }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.actionInProgress)
            .accessibilityLabel("Enviar mensagem")
        }
        .padding()
        .background(.bar)
    }

    // MARK: Cabeçalho (título, máquina · agente, badge de estado)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header (embaixo) mostra SEMPRE o título real vindo do servidor; o
            // apelido local aparece só na nav bar (título do topo).
            Text(model.session.title)
                .font(.title3.weight(.semibold))
            HStack {
                Label("\(model.session.machine) · \(model.session.agent)", systemImage: machineSymbol(model.session.machine))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                StateChip(state: model.session.state)
            }
        }
        .padding()
    }

    // MARK: Output ao vivo estilo terminal

    private var isRunning: Bool { model.session.state == .running }

    private var outputTerminal: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.lines.isEmpty && !isRunning {
                        Text("sem output ainda")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                                lineView(line, isLast: index == model.lines.count - 1)
                                    .id(index)
                            }
                            // Cursor sozinho quando ainda não há output mas está rodando.
                            if model.lines.isEmpty && isRunning {
                                BlinkingCursor()
                            }
                            // Âncora invisível para o auto-scroll e para medir o fim.
                            Color.clear.frame(height: 1)
                                .id("bottom")
                                .background(bottomProbe)
                        }
                        .padding(16)
                    }
                }
                .coordinateSpace(name: "term")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
                // Botão flutuante "descer": aparece quando o fim não está visível.
                .overlay(alignment: .bottomTrailing) {
                    if showScrollToBottom {
                        Button {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.headline)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding()
                        .transition(.opacity.combined(with: .scale))
                        .accessibilityLabel("Descer para o fim")
                    }
                }
                .onChange(of: model.lines.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // Fim visível quando sua posição cai dentro da altura do viewport.
                .onPreferenceChange(BottomOffsetKey.self) { bottomY in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showScrollToBottom = bottomY > outer.size.height + 40
                    }
                }
            }
        }
    }

    /// Mede a posição do fim do conteúdo no espaço de coordenadas do scroll.
    private var bottomProbe: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: BottomOffsetKey.self,
                value: geo.frame(in: .named("term")).minY
            )
        }
    }

    /// Uma linha do terminal; a última ganha o cursor pulsante quando running.
    @ViewBuilder
    private func lineView(_ line: String, isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(line)
            if isLast && isRunning {
                BlinkingCursor()
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cursor pulsante do terminal

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Text("▌")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.green)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Preferência para detectar o fim do scroll

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
