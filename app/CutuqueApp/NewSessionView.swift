import SwiftUI

// MARK: - Nova tarefa (sheet)

/// Formulário para disparar uma nova sessão de agente.
/// Ao criar com sucesso, chama `onCreated` (o chamador fecha a sheet e navega pro detalhe).
struct NewSessionView: View {
    /// Callback com a sessão recém-criada (o pai fecha a sheet e navega).
    let onCreated: (Session) -> Void

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    // Máquinas disponíveis; só `macbook` está habilitado nesta fase.
    private struct MachineOption: Identifiable {
        let id: String
        let label: String
        let enabled: Bool
    }
    private let machines = [
        MachineOption(id: "macbook", label: "macbook", enabled: true),
        MachineOption(id: "desktop-win", label: "desktop-win", enabled: false),
    ]

    // Agente fixo nesta fase.
    private let agent = "claude-code"

    @State private var machine = "macbook"
    @State private var prompt = ""
    @State private var isLaunching = false
    @State private var alertMessage: String?

    private var canLaunch: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLaunching
    }

    var body: some View {
        NavigationStack {
            Form {
                machineSection
                agentSection
                promptSection
            }
            .navigationTitle("Nova tarefa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isLaunching)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLaunching {
                        ProgressView()
                    } else {
                        Button("Disparar") { Task { await launch() } }
                            .fontWeight(.semibold)
                            .disabled(!canLaunch)
                    }
                }
            }
            .alert(
                "Não foi possível disparar",
                isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                ),
                presenting: alertMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: Seções do formulário

    private var machineSection: some View {
        Section("Máquina") {
            ForEach(machines) { option in
                Button {
                    machine = option.id
                } label: {
                    HStack {
                        Text(option.label)
                        if !option.enabled {
                            Text("em breve")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if machine == option.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(!option.enabled)
                .foregroundStyle(option.enabled ? Color.primary : Color.secondary)
            }
        }
    }

    private var agentSection: some View {
        Section("Agente") {
            HStack {
                Text(agent)
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var promptSection: some View {
        Section("Prompt") {
            // Mínimo ~3 linhas de altura.
            TextEditor(text: $prompt)
                .frame(minHeight: 88)
                .font(.body)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("descreva a tarefa para o agente...")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: Disparo

    private func launch() async {
        isLaunching = true
        defer { isLaunching = false }
        do {
            let session = try await api.createSession(machine: machine, agent: agent, prompt: prompt)
            onCreated(session)
        } catch let CutuqueError.server(status, message) {
            // 504 tem UX própria: a sessão pode aparecer na lista mesmo assim.
            alertMessage = status == 504
                ? "o agente demorou a responder — confira a lista, a sessão pode aparecer"
                : message
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
