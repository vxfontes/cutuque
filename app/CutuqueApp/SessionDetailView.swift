import SwiftUI

// MARK: - ViewModel

@MainActor
final class SessionDetailViewModel: ObservableObject {
    /// Sessão exibida; o estado é atualizado ao vivo via `session_updated`.
    @Published var session: Session
    /// Linhas de output acumuladas (histórico + chunks ao vivo).
    @Published var lines: [String] = []

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
            guard let self else { return }
            for await message in self.api.liveUpdates() {
                switch message {
                case .sessionUpdated(let updated) where updated.id == self.session.id:
                    // Só interessa a sessão aberta; atualiza a badge de estado.
                    self.session = updated
                case .outputChunk(let sessionID, let data) where sessionID == self.session.id:
                    // Appenda apenas chunks da sessão aberta.
                    self.lines.append(data)
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
}

// MARK: - Tela de detalhe

struct SessionDetailView: View {
    @StateObject private var model: SessionDetailViewModel

    init(session: Session) {
        _model = StateObject(wrappedValue: SessionDetailViewModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            outputTerminal
        }
        .navigationTitle(model.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Cabeçalho (título, máquina · agente, badge de estado)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.session.title)
                .font(.title3.weight(.semibold))
            HStack {
                Text("\(model.session.machine) · \(model.session.agent)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                StateBadge(state: model.session.state)
            }
        }
        .padding()
    }

    // MARK: Output ao vivo estilo terminal

    private var outputTerminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.lines.isEmpty {
                    Text("sem output ainda")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                        // Âncora invisível para o auto-scroll até o fim.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
            // Rola até o fim quando chega novo output.
            .onChange(of: model.lines.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

// MARK: - Badge de estado

private struct StateBadge: View {
    let state: SessionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(state.color.opacity(0.15), in: Capsule())
        .foregroundStyle(state.color)
    }
}
