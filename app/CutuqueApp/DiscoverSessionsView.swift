import SwiftUI

// MARK: - ViewModel

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var machines: [String] = ["macbook"]
    @Published var machine: String = "macbook"
    @Published var discovered: [DiscoveredSession] = []
    @Published var isLoading = false
    /// ID da sessão sendo adotada agora (mostra spinner na linha), nil = nenhuma.
    @Published var adoptingID: String?
    @Published var errorMessage: String?
    /// Falha ao BUSCAR a lista (hub fora do ar/sem rede) — distinto de "vazio".
    @Published var loadError: String?

    private let api = APIClient()

    /// Carrega as máquinas do hub e já busca as sessões da selecionada.
    func loadTargets() async {
        let fetched = (try? await api.targets()) ?? []
        let list = fetched.isEmpty ? ["macbook"] : fetched
        machines = list
        if !list.contains(machine) { machine = list.first ?? "macbook" }
        await loadSessions()
    }

    /// Lista as sessões do Claude já existentes na máquina selecionada.
    func loadSessions() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            discovered = try await api.discover(machine: machine)
        } catch {
            // Falha real (rede/hub) — distinta de "sem sessões" (lista vazia).
            loadError = error.localizedDescription
            discovered = []
        }
    }

    /// Adota uma sessão descoberta e devolve a Session registrada no hub
    /// (nil em caso de erro — a mensagem vai para `errorMessage`).
    func adopt(_ item: DiscoveredSession) async -> Session? {
        adoptingID = item.id
        defer { adoptingID = nil }
        do {
            return try await api.adopt(machine: machine, discovered: item)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

// MARK: - Sessões do Mac (sheet)

/// Lista as sessões do Claude Code já existentes numa máquina (lidas de
/// ~/.claude/projects lá) para a usuária adotar e continuar a conversa.
/// Ao adotar, chama `onAdopted` (o pai fecha a sheet e navega pro detalhe).
struct DiscoverSessionsView: View {
    /// Callback com a sessão adotada (o pai fecha a sheet e navega).
    let onAdopted: (Session) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DiscoverViewModel()

    var body: some View {
        NavigationStack {
            List {
                if model.machines.count > 1 {
                    Section {
                        Picker("Máquina", selection: $model.machine) {
                            ForEach(model.machines, id: \.self) { name in
                                Label(name, systemImage: machineSymbol(name)).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    if model.isLoading && model.discovered.isEmpty {
                        loadingRow
                    } else if let err = model.loadError, model.discovered.isEmpty {
                        errorRow(err)
                    } else if model.discovered.isEmpty {
                        emptyRow
                    } else {
                        ForEach(model.discovered) { item in
                            NavigationLink(value: item) { rowLabel(item) }
                        }
                    }
                } header: {
                    Text("Sessões recentes")
                } footer: {
                    Text("Toque para ver os detalhes e continuar a conversa.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessões do Mac")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: DiscoveredSession.self) { item in
                DiscoverPreviewView(item: item, machine: model.machine) {
                    // "Continuar": adota e sobe pro pai (fecha a sheet + navega).
                    if let session = await model.adopt(item) {
                        onAdopted(session)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isLoading {
                        ProgressView()
                    }
                }
            }
            .task { await model.loadTargets() }
            .refreshable { await model.loadSessions() }
            // Trocar de máquina recarrega a lista.
            .onChange(of: model.machine) { _, _ in
                Task { await model.loadSessions() }
            }
            .alert(
                "Não foi possível abrir",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                ),
                presenting: model.errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: Linhas

    private func rowLabel(_ item: DiscoveredSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(item.folderName)
                    Text("·")
                    RelativeTimeText(date: item.modifiedAt)
                    if item.count > 0 {
                        Text("·")
                        Text("\(item.count) msgs")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("procurando sessões…").foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz").foregroundStyle(.secondary)
            Text("nenhuma sessão encontrada nessa máquina").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // Distinto de "vazio": aqui a busca FALHOU (hub fora do ar, sem rede).
    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("não consegui buscar as sessões").foregroundStyle(.primary)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

// MARK: - Preview da sessão (confere antes de continuar)

/// Mostra os detalhes de uma sessão descoberta — título completo, árvore de
/// pastas, última mensagem, nº de mensagens, quando — para a usuária confirmar
/// que é a sessão certa ANTES de continuar. "Continuar" adota e retoma.
struct DiscoverPreviewView: View {
    let item: DiscoveredSession
    let machine: String
    /// Chamado ao tocar "Continuar" (adota + retoma no pai).
    let onContinue: () async -> Void

    @State private var isContinuing = false

    var body: some View {
        List {
            Section("Título") {
                Text(item.title)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Section("Pasta") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.pathComponents.enumerated()), id: \.offset) { idx, comp in
                        HStack(spacing: 6) {
                            Image(systemName: idx == item.pathComponents.count - 1 ? "folder.fill" : "folder")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(comp)
                                .font(.system(.callout, design: .monospaced))
                        }
                        .padding(.leading, CGFloat(idx) * 14)
                    }
                }
                .padding(.vertical, 2)
            }

            if !item.last.isEmpty {
                Section("Última mensagem sua") {
                    Text(item.last)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Sessão") {
                // Linhas compactas (HStack + Spacer) em vez de LabeledContent, que
                // em List às vezes estica a linha num container gigante.
                HStack {
                    Text("Máquina").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Label(machine, systemImage: machineSymbol(machine))
                }
                if item.count > 0 {
                    HStack {
                        Text("Mensagens").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text("\(item.count)")
                    }
                }
                HStack {
                    Text("Última atividade").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    RelativeTimeText(date: item.modifiedAt)
                }
                HStack {
                    Text("ID").foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .navigationTitle("Conferir sessão")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    isContinuing = true
                    await onContinue()
                    // Não limpa isContinuing: ao suceder, o pai fecha a sheet.
                }
            } label: {
                HStack {
                    if isContinuing { ProgressView().tint(.white) } else { Image(systemName: "arrow.right.circle.fill") }
                    Text(isContinuing ? "Continuando…" : "Continuar esta sessão")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isContinuing)
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Timestamp relativo (versão reutilizável)

/// Texto relativo ("há 2 min") que se atualiza sozinho a cada 30s.
struct RelativeTimeText: View {
    let date: Date

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(label(relativeTo: context.date))
        }
    }

    private func label(relativeTo now: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 10 { return "agora" }
        return Self.formatter.localizedString(for: date, relativeTo: now)
    }
}
