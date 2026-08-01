import SwiftUI

/// Aba Máquinas: lista os hosts que o hub conhece e cadastra os novos. Tocar
/// num host abre o navegador de arquivos dele (o terminal livre entra na F4).
///
/// A lista NÃO testa a conexão de todas as máquinas ao abrir — seriam N
/// handshakes SSH por refresh, e o alcance só importa quando se entra no host.
struct MachineListView: View {
    @State private var machines: [Machine] = []
    @State private var loading = false
    @State private var error: String?
    /// Cadastro em andamento: máquina nova (`.nova`) ou pendente retomada.
    @State private var cadastro: Cadastro?
    @State private var apagando: Machine?
    private let api = APIClient()

    /// Identifica a sheet de cadastro. `Machine` já é Identifiable, mas "nova"
    /// não tem máquina nenhuma — daí o envelope.
    private enum Cadastro: Identifiable {
        case nova
        case retomar(Machine)

        var id: String {
            switch self {
            case .nova: return "nova"
            case .retomar(let m): return m.name
            }
        }

        var machine: Machine? {
            if case .retomar(let m) = self { return m }
            return nil
        }
    }

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
                    ContentUnavailableView {
                        Label("Nenhuma máquina", systemImage: "server.rack")
                    } description: {
                        Text("Cadastre um host aqui, ou configure CUTUQUE_SSH_TARGETS no hub.env.")
                    } actions: {
                        Button("Cadastrar máquina") { cadastro = .nova }
                    }
                } else {
                    lista
                }
            }
            .navigationTitle("Máquinas")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        cadastro = .nova
                    } label: {
                        Label("Cadastrar máquina", systemImage: "plus")
                    }
                }
            }
            .refreshable { await load() }
            .overlay { if loading && machines.isEmpty { ProgressView() } }
            .task { await load() }
            .sheet(item: $cadastro) { item in
                NewMachineView(retomando: item.machine) { Task { await load() } }
            }
            .confirmationDialog(
                "Remover \(apagando?.name ?? "")?",
                isPresented: .init(get: { apagando != nil }, set: { if !$0 { apagando = nil } }),
                presenting: apagando
            ) { m in
                Button("Remover", role: .destructive) { Task { await apagar(m) } }
            } message: { _ in
                Text("O cadastro e a chave privada saem do hub. A máquina em si não é tocada.")
            }
        }
    }

    private var lista: some View {
        List {
            ForEach(machines) { machine in
                if machine.needsTrust {
                    // Cadastro pela metade não navega: sem a impressão digital
                    // confirmada o hub recusa conectar, e abrir os arquivos só
                    // daria um erro de ssh sem explicação. O toque retoma a
                    // confirmação, que é o que falta de verdade.
                    Button { cadastro = .retomar(machine) } label: { linha(machine) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: machine) { linha(machine) }
                }
            }
            .onDelete { indices in
                // Só as do app têm o que remover; as do hub.env o hub recusa
                // (403), então nem oferece.
                apagando = indices.map { machines[$0] }.first { $0.isEditable }
            }
        }
        .navigationDestination(for: Machine.self) { machine in
            FileBrowserView(machine: machine.name, path: "")
        }
    }

    private func linha(_ machine: Machine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: machine.isLocal ? "desktopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .foregroundStyle(.primary)
                Text(machine.displayDest)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if machine.needsTrust {
                Spacer()
                Label("confirmar", systemImage: "exclamationmark.shield")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("falta confirmar a impressão digital")
            }
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

    private func apagar(_ machine: Machine) async {
        do {
            try await api.deleteMachine(name: machine.name)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
        apagando = nil
    }
}
