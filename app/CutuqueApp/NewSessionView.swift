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

    // Máquinas disponíveis, vindas do hub via /targets (com fallback).
    @State private var machines: [String]
    @State private var machine: String
    /// Agente escolhido: claude-code ou codex.
    @State private var agent = "claude-code"
    @State private var prompt = ""
    /// Pasta onde o agente roda (opcional). Vazio = home da máquina.
    @State private var cwd = ""
    @State private var showingFolderPicker = false
    // Modelo + effort (vazio = default do agente).
    @State private var model = ""
    @State private var effort = ""
    /// Sandbox do Codex (ignorado pelo Claude). Default: workspace-write.
    @State private var sandbox = "workspace-write"
    @State private var isLaunching = false
    @State private var alertMessage: String?

    private var isCodex: Bool { agent == "codex" }

    private let agentOptions: [(id: String, label: String)] = [
        ("claude-code", "Claude Code"), ("codex", "Codex"),
    ]

    // Opções de modelo/effort por agente ("" = default).
    private var modelOptions: [(id: String, label: String)] {
        isCodex
            ? [("", "Padrão"), ("gpt-5", "GPT-5"), ("gpt-5-mini", "GPT-5 mini")]
            : [("", "Padrão"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable")]
    }
    private var effortOptions: [(id: String, label: String)] {
        isCodex
            ? [("", "Padrão"), ("minimal", "Mínimo"), ("low", "Baixo"), ("medium", "Médio"), ("high", "Alto")]
            : [("", "Padrão"), ("low", "Baixo"), ("medium", "Médio"), ("high", "Alto"), ("xhigh", "Muito alto"), ("max", "Máximo")]
    }
    private let sandboxOptions: [(id: String, label: String)] = [
        ("workspace-write", "Workspace (padrão)"), ("read-only", "Somente leitura"), ("danger-full-access", "Acesso total"),
    ]

    private var canLaunch: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLaunching
    }

    var body: some View {
        NavigationStack {
            Form {
                machineSection
                agentSection
                folderSection
                modelSection
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
            // Sheet no nível do Form (estável): preso a uma Section, o SwiftUI
            // reavalia e derruba a apresentação (e a sheet pai junto) — bug do
            // "abre e fecha tudo".
            .sheet(isPresented: $showingFolderPicker) {
                FolderPickerView(machine: machine) { path in cwd = path }
            }
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
        Section {
            Picker("Agente", selection: $agent) {
                ForEach(agentOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            // Modelo/effort têm opções diferentes por agente: reseta para o
            // default ao trocar, evitando um valor inválido pro outro agente.
            .onChange(of: agent) { _, _ in
                model = ""
                effort = ""
            }
        } header: {
            Text("Agente")
        } footer: {
            Text(isCodex
                ? "Codex roda em modo não-interativo (codex exec). A permissão é por sandbox, não por comando."
                : "Claude Code — pede sua aprovação a cada ação sensível.")
        }
    }

    /// Pasta opcional onde o claude roda (cwd). Vazia = home da máquina alvo.
    /// Um seletor navega as pastas do Mac em vez de digitar o caminho.
    private var folderSection: some View {
        Section {
            Button {
                showingFolderPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                    Text(cwd.isEmpty ? "Home da máquina" : cwd)
                        .foregroundStyle(cwd.isEmpty ? .secondary : .primary)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text("Escolher")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !cwd.isEmpty {
                Button("Usar home da máquina") { cwd = "" }
                    .font(.footnote)
            }
        } header: {
            Text("Pasta (opcional)")
        } footer: {
            Text("Navegue as pastas do Mac. Vazio = home da máquina.")
        }
    }

    /// Modelo + effort (+ sandbox no Codex). Vazio = default do agente.
    private var modelSection: some View {
        Section {
            Picker("Modelo", selection: $model) {
                ForEach(modelOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Effort", selection: $effort) {
                ForEach(effortOptions, id: \.id) { Text($0.label).tag($0.id) }
            }
            if isCodex {
                Picker("Sandbox", selection: $sandbox) {
                    ForEach(sandboxOptions, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        } header: {
            Text("Modelo (opcional)")
        } footer: {
            Text(isCodex
                ? "Modelo, esforço e sandbox do Codex. Na dúvida use Padrão — nem todo modelo funciona em conta ChatGPT. O sandbox define o que o Codex pode escrever."
                : "Modelo e esforço de raciocínio do Claude. Padrão = o que o CLI já usa.")
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
            let session = try await api.createSession(machine: machine, agent: agent, prompt: prompt, cwd: cwd, model: model, effort: effort, sandbox: isCodex ? sandbox : nil)
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
