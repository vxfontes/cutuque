import SwiftUI

/// Aba Máquinas: lista os hosts que o hub conhece. Tocar num host abre o
/// navegador de arquivos dele (o terminal livre entra na F4).
///
/// A lista NÃO testa a conexão de todas as máquinas ao abrir — seriam N
/// handshakes SSH por refresh, e o alcance só importa quando se entra no host.
struct MachineListView: View {
    @State private var machines: [Machine] = []
    @State private var loading = false
    @State private var error: String?
    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView {
                        Label("Não deu para listar", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Tentar de novo") { Task { await load() } }
                    }
                } else if machines.isEmpty && !loading {
                    ContentUnavailableView(
                        "Nenhuma máquina",
                        systemImage: "server.rack",
                        description: Text("Configure CUTUQUE_SSH_TARGETS no hub.env.")
                    )
                } else {
                    List(machines) { machine in
                        NavigationLink(value: machine) {
                            HStack(spacing: 10) {
                                Image(systemName: machine.isLocal ? "desktopcomputer" : "server.rack")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(machine.name)
                                    Text(machine.displayDest)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .navigationDestination(for: Machine.self) { machine in
                        FileBrowserView(machine: machine.name, path: "")
                    }
                }
            }
            .navigationTitle("Máquinas")
            .refreshable { await load() }
            .overlay { if loading && machines.isEmpty { ProgressView() } }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            machines = try await api.listMachines()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
