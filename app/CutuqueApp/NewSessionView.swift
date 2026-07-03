import SwiftUI

// MARK: - Nova tarefa (sheet)

/// Formulário para disparar uma nova sessão de agente.
/// Ao criar com sucesso, chama `onCreated` (o chamador fecha a sheet e navega pro detalhe).
struct NewSessionView: View {
    /// Máquina pré-selecionada (ex.: relançar uma sessão encerrada na mesma máquina).
    let initialMachine: String?
    /// Callback com a sessão recém-criada (o pai fecha a sheet e navega).
    let onCreated: (Session) -> Void

    /// `initialMachine` opcional para os chamadores que só passam a closure.
    init(initialMachine: String? = nil, onCreated: @escaping (Session) -> Void) {
        self.initialMachine = initialMachine
        self.onCreated = onCreated
        // Pré-carrega a seleção/lista com a máquina pré-selecionada (ou o fallback)
        // para não piscar vazio antes do /targets responder.
        _machine = State(initialValue: initialMachine ?? "macbook")
        _machines = State(initialValue: initialMachine.map { [$0] } ?? ["macbook"])
    }

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    // Agente fixo nesta fase.
    private let agent = "claude-code"

    // Máquinas disponíveis, vindas do hub via /targets (com fallback).
    @State private var machines: [String]
    @State private var machine: String
    @State private var prompt = ""
    /// Pasta onde o claude roda (opcional). Vazio = home da máquina.
    @State private var cwd = ""
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
                folderSection
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
            // Popula as máquinas do hub; primeira = default (a menos que já haja pré-seleção).
            .task { await loadTargets() }
        }
    }

    // MARK: Seções do formulário

    // Alvos planejados mas ainda não disponíveis no hub (aparecem como "em breve").
    private let plannedMachines = ["desktop-win"]

    private var comingSoon: [String] {
        plannedMachines.filter { !machines.contains($0) }
    }

    private var machineSection: some View {
        Section("Máquina") {
            Picker("Máquina", selection: $machine) {
                ForEach(machines, id: \.self) { name in
                    Label(name, systemImage: machineSymbol(name)).tag(name)
                }
            }
            // Alvos futuros: mostrados desabilitados, não selecionáveis.
            ForEach(comingSoon, id: \.self) { name in
                HStack {
                    Label(name, systemImage: machineSymbol(name))
                    Spacer()
                    Text("em breve").font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// Busca as máquinas disponíveis no hub. Vazio (hub antigo/offline) → fallback.
    private func loadTargets() async {
        let fetched = (try? await api.targets()) ?? []
        var list = fetched.isEmpty ? ["macbook"] : fetched

        // Se veio uma máquina pré-selecionada (relançar) que não está na lista
        // atual, ainda assim a mantemos disponível e selecionada.
        if let initial = initialMachine, !list.contains(initial) {
            list.insert(initial, at: 0)
        }
        machines = list

        // Seleção: mantém a pré-selecionada se válida; senão a primeira da lista.
        if let initial = initialMachine, list.contains(initial) {
            machine = initial
        } else if !list.contains(machine) {
            machine = list.first ?? "macbook"
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

    /// Pasta opcional onde o claude roda (cwd). Vazia = home da máquina alvo.
    private var folderSection: some View {
        Section {
            TextField("/Users/example/projeto", text: $cwd)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } header: {
            Text("Pasta (opcional)")
        } footer: {
            Text("Caminho onde o claude vai rodar. Vazio = home da máquina.")
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
            let session = try await api.createSession(machine: machine, agent: agent, prompt: prompt, cwd: cwd)
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
