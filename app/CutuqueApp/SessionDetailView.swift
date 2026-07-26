import SwiftUI

// MARK: - ViewModel

@MainActor
final class SessionDetailViewModel: ObservableObject {
    /// Sessão exibida; o estado é atualizado ao vivo via `session_updated`.
    @Published var session: Session
    /// Chunks de output acumulados (histórico + chunks ao vivo), já
    /// classificados por `kind` para o transcrito estilo chat.
    @Published var chunks: [OutputChunk] = []
    /// Uma ação (aprovar/negar/enviar) está em andamento — desabilita botões.
    @Published var actionInProgress = false
    /// Aviso transitório para a UI (ex.: estado mudou no 409).
    @Published var notice: String?
    /// Sessão encerrada (done/error) que não deixou transcript no Mac pra
    /// recuperar — não dá pra rever nem retomar (`--resume` falharia). A UI
    /// mostra um estado claro e, ao enviar, começa uma tarefa nova em vez de
    /// tentar (e falhar) o resume.
    @Published var recapUnavailable = false

    private let api = APIClient()
    private var liveTask: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    // MARK: Carga inicial + stream ao vivo

    /// Carrega o histórico de output e assina o stream ao vivo.
    func start() async {
        // Lê o output guardado. Se estiver VAZIO e dá pra reconstruir do transcript
        // do Mac — sessão externa (nunca foi transmitida pelo hub) OU concluída
        // (pode ter perdido o output num restart do hub, e você pode querer rever/
        // continuar a conversa) — importa o transcript e relê. Só quando vazio,
        // pra não duplicar o que já foi transmitido ao vivo.
        var history = (try? await api.output(sessionID: session.id)) ?? []
        let concluded = session.state == .done || session.state == .error
        if history.isEmpty && (session.isExternal || concluded) {
            await api.importHistory(sessionID: session.id)
            history = (try? await api.output(sessionID: session.id)) ?? []
        }
        chunks = Array(history.suffix(Self.maxChunks))
        // Encerrada e AINDA vazia após tentar importar → não há transcript no
        // Mac pra recuperar (ex.: uma sessão que deu erro antes de salvar nada).
        recapUnavailable = history.isEmpty && concluded
        startLiveUpdates()
    }

    /// Teto de chunks mantidos, alinhado ao `maxOutputChunks` do hub (500) para
    /// caber o histórico importado ao adotar uma sessão do Mac.
    static let maxChunks = 500

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
                case .outputChunk(let sessionID, let kind, let text) where sessionID == self.session.id:
                    // Appenda apenas chunks da sessão aberta, espelhando o teto
                    // do hub (maxChunks=500) para não crescer sem limite e não
                    // descartar o histórico importado (review #2).
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.chunks.append(OutputChunk(kind: kind, text: text))
                    }
                    if self.chunks.count > Self.maxChunks {
                        self.chunks.removeFirst(self.chunks.count - Self.maxChunks)
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

    /// Interrompe o turno em andamento (card 6b74500a1fd9a1f2). Não usa
    /// `runAction` porque precisa do `effect` devolvido pelo hub ("paused" —
    /// sessão tmux-adotada, Esc no pane, CONTINUA rodando — ou "ended" —
    /// pipe-mode, processo encerrado) para avisar corretamente qual dos dois
    /// aconteceu; nunca prometemos de antemão qual vai ser (a confirmação, na
    /// view, já hedge isso conforme `session.pane`).
    func interrupt() async {
        actionInProgress = true
        defer { actionInProgress = false }
        do {
            let effect = try await api.interrupt(sessionID: session.id)
            notice = effect == "paused"
                ? "o agente pausou — pode responder"
                : "sessão encerrada — o turno não foi salvo (mande uma mensagem nova pra continuar)"
            await reloadSession()
        } catch CutuqueError.staleState {
            await reloadSession()
            notice = "o estado mudou"
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Responde a uma ou mais perguntas de seleção pendentes (AskUserQuestion).
    /// Igual às demais ações: 409 recarrega a sessão e avisa "o estado mudou"
    /// (o card de pergunta some sozinho quando a sessão sai de needs_you).
    func answerQuestions(_ answers: [APIClient.AnswerItem]) async {
        await runAction { try await self.api.answer(sessionID: self.session.id, answers: answers) }
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
    @EnvironmentObject private var nav: NavigationState
    /// Falso quando esta view está viva na hierarquia mas escondida atrás do
    /// terminal (painel Chat|Terminal do iPad, `SessionDetailPane`, decisão
    /// #19). Default `true` preserva o iPhone, que só monta um painel por
    /// vez e nunca chama isto com `false`.
    var isActive: Bool = true
    @State private var draft = ""
    @State private var showScrollToBottom = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showingDetails = false
    // Sheet paginado de perguntas (card 4c76eb0d0b8f3337) — capturamos o set
    // no momento do toque no CTA (`questionsBanner`) em vez de ler
    // `pendingQuestions` ao vivo de dentro do sheet: assim, se a sessão sair
    // de needs_you enquanto o sheet está aberto (respondida por outro
    // cliente, timeout), não corremos risco de o array virar vazio debaixo
    // da view — o `.onChange` abaixo fecha o sheet nesse caso.
    @State private var showQuestionSheet = false
    @State private var sheetQuestions: [PendingQuestion] = []
    // Confirmação do botão de parar (card 6b74500a1fd9a1f2) — destrutivo no
    // caminho comum (mata o processo pipe-mode); hedge porque sessões
    // tmux-adotadas só pausam (ver `isTmuxBacked`).
    @State private var confirmingInterrupt = false
    // Foco do campo de digitação — a barra sobe corretamente com o teclado
    // porque só o transcrito (ScrollView) ignora a safe area do teclado;
    // a VStack externa, essa sim, empurra a barra pra cima normalmente.
    @FocusState private var inputFocused: Bool

    init(session: Session, isActive: Bool = true) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
        self.isActive = isActive
    }

    /// Título a exibir (apelido local, se houver, senão o original).
    private var displayTitle: String { namer.displayTitle(for: model.session) }

    /// Chunks crus agrupados em itens de chat: linhas consecutivas do mesmo
    /// papel (usuário/assistente) se fundem num só bloco; tool + tool_result
    /// viram um grupo recolhível — é o que resolve a reclamação de tool call
    /// "competindo" visualmente com a resposta do agente.
    private var chatItems: [ChatItem] { ChatItem.grouping(model.chunks) }

    /// Perguntas de seleção pendentes (ferramenta AskUserQuestion), quando o
    /// pedido pendente NÃO é uma permissão comum sim/não. SÓ para sessões
    /// lançadas pelo app (mesma regra do `permissionPrompt`) — sessões
    /// externas respondem no terminal.
    private var pendingQuestions: [PendingQuestion]? {
        guard model.session.state == .needsYou, !model.session.isExternal,
              let questions = model.session.pendingQuestions, !questions.isEmpty
        else { return nil }
        return questions
    }

    /// Texto do pedido de permissão, se houver, quando a sessão precisa de você.
    /// SÓ para sessões lançadas pelo app (que o hub controla) — nessas o
    /// aprovar/negar funciona. Sessões externas (hook/tmux) respondem no terminal.
    /// Mutuamente exclusivo com `pendingQuestions` — quando o pedido é uma
    /// pergunta, o card de pergunta manda, nunca o sim/não.
    private var permissionPrompt: String? {
        guard model.session.state == .needsYou, !model.session.isExternal,
              (model.session.pendingQuestions ?? []).isEmpty,
              let prompt = model.session.pendingPrompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return prompt
    }

    /// Pedido de uma sessão EXTERNA (hook) em needs_you: mostra o texto mas SEM
    /// aprovar/negar (o hub não controla o gate dela — a resposta é no terminal).
    private var externalPrompt: String? {
        guard model.session.state == .needsYou, model.session.isExternal else { return nil }
        let p = model.session.pendingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? "O agente está esperando você." : p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Card de permissão acima do terminal (invariante docs/04: sempre
            // exibe o texto — aprovar/negar nunca pode ser às cegas). Pergunta
            // de seleção NÃO fica mais fixa aqui (card 4c76eb0d0b8f3337): ela
            // cobria a tela e empurrava pra baixo a explicação do agente, que
            // é só mais uma bolha no transcrito logo abaixo. Agora vira um CTA
            // fino perto do campo (`questionsBanner`, dentro de
            // `interactionBar`) que abre um sheet paginado sob demanda —
            // o transcrito flui livre, sem nada pinado por cima.
            if let prompt = permissionPrompt {
                permissionCard(prompt)
            } else if let prompt = externalPrompt {
                externalPromptCard(prompt)
            }
            transcript
            // Barra de digitação SEMPRE visível. Em sessão viva, o texto responde
            // ao agente em andamento; em sessão encerrada (sem processo vivo), o
            // texto lança uma nova tarefa na mesma máquina (relançar).
            interactionBar
        }
        // `isActive` gate no VALOR do título e no CONTEÚDO do toolbar — não no
        // modificador em si — pelo mesmo motivo do `TerminalMirrorView`: as
        // duas views ficam montadas ao mesmo tempo no painel do iPad
        // (`SessionDetailPane`), e `.toolbar`/`.navigationTitle` de views
        // simultâneas na hierarquia disputam a mesma barra, sem que
        // `.opacity`/`.allowsHitTesting` (que só afetam a área de conteúdo)
        // resolvam isso.
        .navigationTitle(isActive ? displayTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        // ⌘. — abre a MESMA confirmação do botão de parar; no pipe-mode isso
        // mata a sessão, então o atalho não pula o gate.
        //
        // Só consome o que trata: a lista de sessões está viva na outra coluna
        // da split view e espera pelos intents dela.
        .onChange(of: nav.intent) { _, intent in
            guard intent == .interrupt else { return }
            nav.consume()
            confirmingInterrupt = true
        }
        .toolbar {
            if isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingDetails = true
                        } label: {
                            Label("Detalhes", systemImage: "info.circle")
                        }
                        Button {
                            renameText = namer.customName(for: model.session.id) ?? model.session.title
                            renaming = true
                        } label: {
                            Label("Renomear", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Mais opções")
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ChatDetailsView(session: model.session, displayTitle: displayTitle)
            }
        }
        .sheet(isPresented: $showQuestionSheet) {
            NavigationStack {
                QuestionCardView(
                    questions: sheetQuestions,
                    actionInProgress: model.actionInProgress,
                    onSubmit: { answers in
                        showQuestionSheet = false
                        Task { await model.answerQuestions(answers) }
                    },
                    onCancel: {
                        showQuestionSheet = false
                        Task { await model.deny() }
                    }
                )
                .navigationTitle("Precisa de você")
                .navigationBarTitleDisplayMode(.inline)
                // Sem botão de fechar na toolbar de propósito: o "Cancelar"
                // (que de fato nega o pedido) já está no rodapé do
                // QuestionCardView. Swipe-down só fecha o sheet sem decidir
                // nada — a sessão continua needs_you e o CTA reabre depois.
            }
        }
        // Sessão saiu de needs_you (respondida por outro cliente/terminal,
        // timeout, ou a própria resposta) enquanto o sheet estava aberto →
        // fecha sozinho, mesmo princípio do card fixo de antes.
        .onChange(of: pendingQuestions) { _, newValue in
            if newValue == nil { showQuestionSheet = false }
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    /// Card para sessão EXTERNA em needs_you: mostra o pedido, sem aprovar/negar
    /// (o hub não controla; responde no terminal do Mac).
    private func externalPromptCard(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Precisa de você", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(prompt)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Label("Responda no terminal do Mac (ou abra o terminal ao vivo).", systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
    }

    // MARK: Barra de interação (responder OU relançar, conforme o estado)

    /// Viva (rodando/precisa de você): há processo pra receber o texto.
    private var isLive: Bool {
        model.session.state == .running || model.session.state == .needsYou
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.actionInProgress
    }

    /// Sessão tmux-adotada (TUI de verdade por trás do pane, `pane` não
    /// vazio) — o interrupt manda só Esc ao pane e a sessão CONTINUA
    /// rodando (hub: `Launcher.Interrupt`, `InterruptEffectPaused`). Sem pane
    /// (caminho principal, pipe-mode) o interrupt mata o processo — não há
    /// primitiva de "abortar só o turno" no protocolo do CLI headless hoje
    /// (`InterruptEffectEnded`). Usamos isso pra avisar certo ANTES de agir —
    /// nunca prometer pausa quando na prática vai encerrar, nem assustar com
    /// "encerra" quando na prática só pausa.
    private var isTmuxBacked: Bool {
        !(model.session.pane ?? "").isEmpty
    }

    /// Barra moderna: campo que cresce com o texto + botão circular de enviar.
    /// A mensagem enviada aparece como bolha no transcrito via o eco do
    /// hub (WS `output_chunk` kind=user) — não fazemos eco otimista aqui.
    /// Respostas rápidas de um toque — enviam o texto na hora (sem digitar).
    private static let quickReplies = [
        "Sim, prossiga", "Continua", "Rode os testes", "Commita", "Explica melhor", "Não, cancela",
    ]

    /// Há uma permissão ou pergunta pendente — o CLI está travado esperando o
    /// `control_response` nativo dela. Um quick reply nesse meio-tempo iria pro
    /// stdin como mensagem solta, sem responder o pedido em si (e sem gente
    /// tocar Aprovar/Negar ou o seletor da pergunta, que respondem pelo canal
    /// certo) — oculta a barra pra não convidar a isso.
    private var hasPendingGate: Bool {
        model.session.pendingPrompt != nil || !(model.session.pendingQuestions ?? []).isEmpty
    }

    @ViewBuilder private var quickRepliesBar: some View {
        if !hasPendingGate {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button {
                            Task { _ = await model.sendInput(reply) }
                        } label: {
                            Text(reply)
                                .font(.footnote)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.actionInProgress)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    /// CTA fino perto do campo (card 4c76eb0d0b8f3337) — substitui os quick
    /// replies (que já se ocultam sozinhos via `hasPendingGate`) quando há
    /// perguntas pendentes. Mostra o `header` direto se for 1 pergunta só;
    /// "N perguntas pendentes" se for um set. Ao tocar, CAPTURA o set em
    /// `sheetQuestions` (não lê `pendingQuestions` ao vivo de dentro do
    /// sheet) e abre o sheet paginado.
    @ViewBuilder private var questionsBanner: some View {
        if let questions = pendingQuestions {
            Button {
                sheetQuestions = questions
                showQuestionSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                    Text(questions.count == 1 ? questions[0].header : "\(questions.count) perguntas pendentes")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("Responder")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.actionInProgress)
            .padding(.horizontal, 12)
            .accessibilityLabel(
                questions.count == 1
                    ? "Responder pergunta: \(questions[0].header)"
                    : "Responder \(questions.count) perguntas pendentes"
            )
        }
    }

    private var interactionBar: some View {
      VStack(spacing: 8) {
        questionsBanner
        quickRepliesBar
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                isLive ? "Responda ao agente…" : "Continue a conversa…",
                text: $draft, axis: .vertical
            )
            .font(.body)
            .lineLimit(1...6)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .focused($inputFocused)

            Button {
                // Rodando: o botão circular vira "parar" (card 6b74500a1fd9a1f2)
                // — pede confirmação antes (destrutivo no caminho comum).
                if isRunning {
                    confirmingInterrupt = true
                    return
                }
                let text = draft
                Task {
                    if model.recapUnavailable {
                        // Sessão morta (encerrou sem transcript): não dá pra
                        // retomar. "Continuar" = começar uma tarefa nova na
                        // mesma máquina e navegar até ela.
                        if let novo = await model.launchNew(text) {
                            draft = ""
                            router.openSession(novo.id)
                        }
                    } else if await model.sendInput(text) {
                        // Viva → responde ao agente em andamento; encerrada com
                        // transcript → o hub retoma (claude --resume) e a
                        // resposta chega nesta mesma tela via WS.
                        draft = ""
                    }
                }
            } label: {
                Group {
                    if model.actionInProgress {
                        ProgressView()
                            .tint(.white)
                    } else if isRunning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(
                    isRunning ? Color.red : (canSend ? Color.accentColor : Color.gray.opacity(0.35)),
                    in: Circle()
                )
            }
            .disabled(isRunning ? model.actionInProgress : !canSend)
            .animation(.snappy, value: canSend)
            .animation(.snappy, value: isRunning)
            .accessibilityLabel(isRunning ? "Parar o agente" : "Enviar mensagem")
            .confirmationDialog(
                isTmuxBacked ? "Interromper o turno?" : "Encerrar o turno?",
                isPresented: $confirmingInterrupt,
                titleVisibility: .visible
            ) {
                Button(isTmuxBacked ? "Interromper" : "Encerrar", role: .destructive) {
                    Task { await model.interrupt() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(
                    isTmuxBacked
                        ? "Manda Esc pro terminal — a sessão continua rodando, só o turno atual é abortado."
                        : "Essa sessão não tem como só abortar o turno — o processo é encerrado e o progresso não salvo se perde (dá pra continuar mandando uma mensagem nova depois)."
                )
            }
        }
        .padding(.horizontal, 12)
      }
      .padding(.vertical, 10)
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

    // MARK: Transcrito estilo chat

    private var isRunning: Bool { model.session.state == .running }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    if chatItems.isEmpty && !isRunning {
                        emptyTranscript
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(chatItems) { item in
                                chatItemView(item)
                                    .id(item.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            // Indicador discreto de "digitando" enquanto o agente roda.
                            if isRunning {
                                TypingIndicator()
                            }
                            // Âncora invisível para o auto-scroll e para medir o fim.
                            Color.clear.frame(height: 1)
                                .id("bottom")
                                .background(bottomProbe)
                        }
                        .padding(16)
                        // SEM .animation(value: chatItems.count) aqui: agora que ChatItem
                        // tem identidade estável (id herdado do OutputChunk que originou o
                        // grupo), o .transition acima só dispara pra itens genuinamente
                        // novos. O append ao vivo já é animado no ViewModel
                        // (startLiveUpdates, withAnimation no append) — duplicar a animação
                        // aqui, num LazyVStack, era o que deixava linhas fora da viewport
                        // presas em opacidade intermediária (bug do transcrito sumindo —
                        // card d1a0796400fb73f0).
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: "term")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(.systemGroupedBackground))
                // Só o transcrito ignora a safe area do teclado: assim ele não
                // tenta compensar a altura do teclado por conta própria (o que
                // causaria um "pulo" duplo), enquanto a VStack externa continua
                // empurrando a interactionBar pra cima normalmente.
                .ignoresSafeArea(.keyboard, edges: .bottom)
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
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .padding()
                        .transition(.opacity.combined(with: .scale))
                        .accessibilityLabel("Descer para o fim")
                    }
                }
                .onChange(of: chatItems.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: isRunning) { _, _ in
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

    /// Estado vazio convidativo antes do primeiro chunk chegar.
    private var emptyTranscript: some View {
        VStack(spacing: 10) {
            Image(systemName: model.recapUnavailable ? "clock.badge.xmark" : "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(model.recapUnavailable ? "sem histórico salvo" : "sem mensagens ainda")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if model.recapUnavailable {
                Text("Essa sessão encerrou sem deixar registro pra recuperar. Envie uma mensagem para começar uma tarefa nova nesta máquina.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
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

    /// Desenha um item do transcrito conforme seu papel.
    @ViewBuilder
    private func chatItemView(_ item: ChatItem) -> some View {
        switch item.content {
        case .user(let text):
            userBubble(text)
        case .assistant(let text):
            assistantBlock(text)
        case .tool(let command, let result):
            ToolGroupView(command: command, result: result)
        }
    }

    /// Mensagem que VOCÊ enviou — bolha à direita, cor de destaque.
    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Resposta do agente — markdown renderizado à esquerda, com um avatarzinho.
    private func assistantBlock(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar()
            MarkdownText(text: text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, 3)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Avatar discreto do agente

private struct AgentAvatar: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.accentColor.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Grupo tool + tool_result (linha discreta e recolhível)

/// Linha compacta e discreta pra chamadas de ferramenta — não deve competir
/// visualmente com a resposta do agente. Toque expande o resultado, se houver.
private struct ToolGroupView: View {
    let command: String
    let result: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard result != nil else { return }
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text(command)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if result != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(result == nil)

            if expanded, let result {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Indicador discreto de "digitando" (cursor pulsante da Fase 2)

private struct TypingIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentAvatar()
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 1 : 0.25)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel("agente digitando")
    }
}

// MARK: - Itens do transcrito (agrupamento de chunks crus)

/// Item pronto pra desenhar no transcrito: já agrupado a partir dos
/// `OutputChunk` crus (ver `grouping(_:)`). `id` é herdado do `OutputChunk`
/// que ORIGINOU o grupo (o primeiro chunk daquele item) e permanece o MESMO
/// através dos merges — identidade estável pro `ForEach`. Antes disso o
/// `ForEach` usava o índice do array como id: como `grouping(_:)` recomputa
/// tudo a cada render (merges de `.assistant`, resolução retroativa de
/// `tool_result` num item mais antigo, trim de `model.chunks` na frente), o
/// mapeamento índice→conteúdo não era estável entre renders, e o SwiftUI
/// tratava linhas existentes como removidas/inseridas — combinado com
/// `.transition` + `.animation` num `LazyVStack` (que só materializa linhas
/// visíveis), linhas fora da viewport ficavam presas em opacidade
/// intermediária até um remount completo (sair/reentrar). Ver card
/// d1a0796400fb73f0.
private struct ChatItem: Identifiable {
    let id: UUID
    var content: Content

    enum Content {
        case user(String)
        case assistant(String)
        /// Uma tool call e, se já chegou, seu resultado (tool_result).
        case tool(command: String, result: String?)
    }

    /// Agrupa a lista crua e cronológica de chunks. `.assistant` consecutivos
    /// se fundem (evita várias bolhas picadas pro streaming do mesmo turno).
    /// `.user` NUNCA funde — cada input da usuária já chega inteiro num chunk
    /// só (diferente do assistente, que estrema em pedaços); fundir bolhas de
    /// usuário era o que causava o "chip de resposta rápida concatenado com o
    /// prompt inicial" (card 1297f46a93f95b40): quando o agente pedia
    /// permissão/pergunta sem responder nada em texto antes, o prompt inicial
    /// ficava como último chunk `.user` do histórico, e o eco do chip (também
    /// `.user`) se fundia visualmente nele com "\n" — dois envios distintos e
    /// corretos, mas mostrados como um só. tool + tool_result que vêm em
    /// seguida viram um único grupo recolhível.
    static func grouping(_ chunks: [OutputChunk]) -> [ChatItem] {
        var items: [ChatItem] = []
        for chunk in chunks {
            switch chunk.kind {
            case .user:
                // Sempre um item novo, com o id do próprio chunk — nunca funde
                // com o item anterior (ver doc acima).
                items.append(ChatItem(id: chunk.id, content: .user(chunk.text)))
            case .assistant:
                if let last = items.last, case .assistant(let previous) = last.content {
                    items[items.count - 1].content = .assistant(previous + "\n" + chunk.text)
                } else {
                    items.append(ChatItem(id: chunk.id, content: .assistant(chunk.text)))
                }
            case .tool:
                // CADA tool call é um item próprio — o Claude emite vários
                // tool_use no mesmo turno (ex.: 2 Reads paralelos) e fundir
                // esconderia todas menos a primeira (review UX, bloqueante).
                items.append(ChatItem(id: chunk.id, content: .tool(command: chunk.text, result: nil)))
            case .toolResult:
                // Pareia com a tool pendente mais ANTIGA sem resultado: os
                // tool_result chegam na ordem das chamadas (FIFO). Reusa o id
                // do item da tool (não o do chunk de resultado) — a identidade
                // da linha continua sendo a da tool call, só o conteúdo muda.
                if let idx = items.firstIndex(where: {
                    if case .tool(_, let r) = $0.content { return r == nil }
                    return false
                }) {
                    if case .tool(let command, _) = items[idx].content {
                        items[idx].content = .tool(command: command, result: chunk.text)
                    }
                } else {
                    // Borda: tool_result sem tool anterior (histórico truncado).
                    items.append(ChatItem(id: chunk.id, content: .tool(command: "resultado", result: chunk.text)))
                }
            }
        }
        return items
    }
}

// MARK: - Preferência para detectar o fim do scroll

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Detalhes da sessão (metadados + árvore de pastas)

/// Sheet de detalhes de uma sessão de chat: metadados + árvore da pasta (cwd),
/// no mesmo estilo do LiveDetailView das sessões de tmux.
private struct ChatDetailsView: View {
    let session: Session
    let displayTitle: String
    @Environment(\.dismiss) private var dismiss

    /// Componentes da pasta (cwd) para a árvore, sem o "/" inicial.
    private var pathComponents: [String] {
        (session.cwd ?? "").split(separator: "/").map(String.init)
    }

    var body: some View {
        List {
            Section("Sessão") {
                detailRow("Nome", displayTitle)
                detailRow("Estado", session.state.label)
                detailRow("Máquina", session.machine, symbol: machineSymbol(session.machine))
                detailRow("Agente", session.agent)
                detailRow("Origem", session.isExternal ? "detectada (hook/terminal)" : "lançada pelo app")
                detailRow("ID", session.id, mono: true)
            }
            if !pathComponents.isEmpty {
                Section("Pasta") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pathComponents.enumerated()), id: \.offset) { idx, comp in
                            HStack(spacing: 6) {
                                Image(systemName: idx == pathComponents.count - 1 ? "folder.fill" : "folder")
                                    .foregroundStyle(.secondary).font(.caption)
                                Text(comp).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            }
                            .padding(.leading, CGFloat(idx) * 14)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Detalhes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Fechar") { dismiss() } }
        }
    }

    /// Linha compacta (rótulo à esquerda, valor à direita em uma linha só). Mesma
    /// abordagem do LiveDetailView (evita o LabeledContent que estica em List).
    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, symbol: String? = nil, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(value)
                    .font(mono ? .caption.monospaced() : .body)
                    .foregroundStyle(mono ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
