import SwiftUI

// MARK: - Histórico (sessões passadas + linha do tempo)

/// Lista as sessões passadas do histórico (persistido no Postgres pelo hub) e,
/// ao tocar, mostra a linha do tempo de eventos daquela sessão. Somente-leitura:
/// é o registro do que aconteceu, sobrevive ao TTL/limpeza do registry vivo.
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [Session] = []
    @State private var loading = true
    @State private var loadError: String?
    private let api = APIClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading && sessions.isEmpty {
                        loadingRow
                    } else if let e = loadError, sessions.isEmpty {
                        errorRow(e)
                    } else if sessions.isEmpty {
                        emptyRow
                    } else {
                        ForEach(sessions) { s in
                            NavigationLink(value: s) { row(s) }
                        }
                    }
                } footer: {
                    Text("Sessões passadas e sua linha do tempo, guardadas no hub. Só leitura.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Histórico")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Session.self) { HistoryTimelineView(session: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { if loading { ProgressView() } }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            sessions = try await api.history(limit: 200)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func row(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.title.isEmpty ? s.id : s.title)
                .font(.body).foregroundStyle(.primary).lineLimit(2)
            HStack(spacing: 4) {
                Text(agentLabel(s.agent)).fontWeight(.semibold).foregroundStyle(agentColor(s.agent))
                Text("·")
                Text(s.state.label)
                Text("·")
                RelativeTimeText(date: s.updatedAt)
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var loadingRow: some View {
        HStack(spacing: 10) { ProgressView(); Text("carregando histórico…").foregroundStyle(.secondary) }
    }
    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark").foregroundStyle(.secondary)
            Text("sem histórico ainda (ou o hub está sem Postgres)").foregroundStyle(.secondary)
        }.font(.callout)
    }
    private func errorRow(_ m: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("não consegui carregar o histórico").foregroundStyle(.primary)
                Text(m).font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout)
    }
}

// MARK: - Linha do tempo de uma sessão

/// Renderiza os eventos de uma sessão passada em ordem cronológica.
struct HistoryTimelineView: View {
    let session: Session
    @State private var events: [HistoryEvent] = []
    @State private var loading = true
    private let api = APIClient()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if loading && events.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if events.isEmpty {
                    Text("sem eventos").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(events) { eventRow($0) }
                }
            }
            .padding()
        }
        .navigationTitle(session.title.isEmpty ? "Sessão" : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        events = (try? await api.historyEvents(sessionID: session.id)) ?? []
    }

    @ViewBuilder private func eventRow(_ e: HistoryEvent) -> some View {
        if e.type == "output_chunk" {
            chunkRow(kind: e.kind, text: e.data)
        } else {
            lifecycleRow(e.type)
        }
    }

    /// Um chunk de conversa (user/assistant/tool/tool_result), estilo transcrito.
    private func chunkRow(kind: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chunkLabel(kind))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(chunkColor(kind))
            Text(text)
                .font(kind == "tool" || kind == "tool_result" ? .system(.footnote, design: .monospaced) : .callout)
                .foregroundStyle(kind == "tool_result" ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Marcador de ciclo de vida (iniciou/concluiu/erro/precisa de você).
    private func lifecycleRow(_ type: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: lifecycleIcon(type))
            Text(lifecycleLabel(type))
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private func chunkLabel(_ k: String) -> String {
        switch k {
        case "user": return "Você"
        case "assistant": return "Agente"
        case "tool": return "Ferramenta"
        case "tool_result": return "Resultado"
        default: return k
        }
    }
    private func chunkColor(_ k: String) -> Color {
        switch k {
        case "user": return .blue
        case "assistant": return .primary
        default: return .secondary
        }
    }
    private func lifecycleIcon(_ t: String) -> String {
        switch t {
        case "session_started": return "play.circle"
        case "finished": return "checkmark.circle"
        case "errored": return "xmark.octagon"
        case "needs_input", "permission_requested": return "exclamationmark.bubble"
        case "user_responded": return "arrowshape.turn.up.right"
        default: return "circle"
        }
    }
    private func lifecycleLabel(_ t: String) -> String {
        switch t {
        case "session_started": return "sessão iniciada"
        case "finished": return "concluída"
        case "errored": return "erro"
        case "needs_input", "permission_requested": return "precisou de você"
        case "user_responded": return "você respondeu"
        default: return t
        }
    }
}

// Rótulo/cor do agente reaproveitados na lista de histórico.
private func agentLabel(_ a: String) -> String {
    switch a {
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    default: return "Claude"
    }
}
private func agentColor(_ a: String) -> Color {
    switch a {
    case "codex": return .purple
    case "opencode": return .green
    default: return .orange
    }
}
