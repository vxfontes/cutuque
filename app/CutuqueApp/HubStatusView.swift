import SwiftUI

/// Modal de status do hub, aberto ao tocar na bolinha de saúde. Mostra o
/// endereço atual, se está online, a latência medida e um resumo do que está
/// conectado (sessões por estado e máquinas ativas). Tudo apontando pro hub
/// configurado (o ZimaOS após o deploy).
struct HubStatusView: View {
    /// Sessões atuais (já carregadas pela lista) para o resumo de "conectado".
    let sessions: [Session]
    /// Sessões rodando ao vivo no Mac (panes do tmux), pro status refletir isso.
    var live: [LiveEntry] = []

    @Environment(\.dismiss) private var dismiss
    @State private var online: Bool?
    @State private var latencyMs: Int?
    @State private var measuring = false
    private let api = APIClient()

    // Ordem de exibição dos estados no resumo.
    private let statesInOrder: [SessionState] = [.needsYou, .running, .done, .error, .idle]

    private var machines: [String] {
        Array(Set(sessions.map(\.machine))).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Servidor") {
                    LabeledContent("Endereço") {
                        Text(HubSettings.baseURL.absoluteString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 10, height: 10)
                            Text(statusText)
                        }
                    }
                    LabeledContent("Tempo de resposta") {
                        if measuring {
                            ProgressView()
                        } else if let ms = latencyMs {
                            Text("\(ms) ms").foregroundStyle(latencyColor(ms))
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Conectado") {
                    LabeledContent("Sessões", value: "\(sessions.count)")
                    ForEach(statesInOrder, id: \.self) { st in
                        let n = sessions.filter { $0.state == st }.count
                        if n > 0 {
                            LabeledContent {
                                Text("\(n)")
                            } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(st.color).frame(width: 8, height: 8)
                                    Text(st.label)
                                }
                            }
                        }
                    }
                    if !machines.isEmpty {
                        LabeledContent("Máquinas") {
                            HStack(spacing: 10) {
                                ForEach(machines, id: \.self) { m in
                                    Label(m, systemImage: machineSymbol(m))
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !live.isEmpty {
                    Section {
                        ForEach(live) { entry in
                            HStack(spacing: 10) {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.session.title).lineLimit(1)
                                    Text("\(entry.machine) · \(entry.session.folderName)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Label("Ao vivo no Mac (\(live.count))", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green).textCase(nil)
                    }
                }
            }
            .navigationTitle("Status do hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await measure() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(measuring)
                    .accessibilityLabel("Medir novamente")
                }
            }
            .task { await measure() }
        }
    }

    private func measure() async {
        measuring = true
        defer { measuring = false }
        let r = await api.healthLatency()
        online = r.online
        latencyMs = r.ms
    }

    private var statusColor: Color {
        switch online {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private var statusText: String {
        switch online {
        case .some(true): return "online"
        case .some(false): return "offline"
        case .none: return "verificando…"
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<80: return .green
        case ..<250: return .orange
        default: return .red
        }
    }
}
