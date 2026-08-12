import SwiftUI

/// Os quatro do `scripts/tmx.sh`. "terminal" é o shell puro — o terminal livre nasce
/// sem agente nenhum (D8). O `rawValue` é o que viaja no POST: o hub usa essa string
/// como chave da tabela de comandos.
enum AgenteNovoTerminal: String, CaseIterable, Identifiable {
    case claude, codex, opencode, terminal

    var id: String { rawValue }

    var rotulo: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .terminal: return "Terminal vazio"
        }
    }

    var simbolo: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "cube"
        case .terminal: return "terminal"
        }
    }
}

struct NovoTerminalCampos: Equatable {
    var machine: String = ""
    var grupo: String = ""
    var sessao: String = ""
    var pasta: String = ""
    var agente: AgenteNovoTerminal = .claude
}

/// Lógica pura do formulário, fora da View para dar teste sem simulador.
enum NovoTerminalFormLogic {
    static func podeCriar(_ campos: NovoTerminalCampos) -> Bool {
        !campos.machine.isEmpty
            && NomeTmux.valido(campos.grupo)
            && NomeTmux.valido(campos.sessao)
            && campos.pasta.hasPrefix("/")
    }

    /// Sugestões de grupo, tiradas do que já está ao vivo. Sugestão, não menu
    /// fechado: digitar um nome que não existe é criar o grupo (D13) — e criar grupo
    /// novo cria escopo novo no board, que é consequência declarada.
    ///
    /// Desvio do plano (12/08/2026): o plano original pedia `[GrupoAoVivo]` (tipo da
    /// Task E1). A chain E roda em paralelo noutro worktree e o tipo não existe aqui
    /// — recebe `[String]` (nomes de grupo já ao vivo) e a Task F3 faz o `map` no
    /// call site quando a chain E estiver mergeada.
    static func gruposConhecidos(_ grupos: [String]) -> [String] {
        Array(Set(grupos)).sorted()
    }
}

/// Formulário de novo terminal tmux. Cinco campos, cinco fontes que já existiam.
struct NovoTerminalForm: View {
    let maquinas: [String]
    let gruposSugeridos: [String]
    /// Chamado com (máquina, alvo do pane) quando a criação dá certo.
    let aoCriar: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    @State private var campos = NovoTerminalCampos()
    @State private var criando = false
    @State private var erro: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Máquina") {
                    Picker("Máquina", selection: $campos.machine) {
                        ForEach(maquinas, id: \.self) { m in
                            Label(m, systemImage: machineSymbol(m)).tag(m)
                        }
                    }
                }

                Section {
                    TextField("Grupo", text: $campos.grupo)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: campos.grupo) { _, novo in
                            // D12: filtra enquanto digita, em vez de reclamar depois.
                            let limpo = NomeTmux.filtrando(novo)
                            if limpo != novo { campos.grupo = limpo }
                        }
                    if !gruposSugeridos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(gruposSugeridos, id: \.self) { g in
                                    Button(g) { campos.grupo = g }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Grupo")
                } footer: {
                    Text("\(NomeTmux.aviso). Nome novo cria o grupo.")
                }

                Section {
                    TextField("Sessão", text: $campos.sessao)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: campos.sessao) { _, novo in
                            let limpo = NomeTmux.filtrando(novo)
                            if limpo != novo { campos.sessao = limpo }
                        }
                } header: {
                    Text("Sessão")
                } footer: {
                    Text("Sessão que já existe é reaproveitada, não duplicada.")
                }

                Section("Pasta") {
                    NavigationLink {
                        SeletorDePasta(machine: campos.machine, escolhida: $campos.pasta)
                    } label: {
                        HStack {
                            Text("Pasta")
                            Spacer()
                            Text(campos.pasta.isEmpty ? "escolher" : campos.pasta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .disabled(campos.machine.isEmpty)
                }

                Section("Agente") {
                    Picker("Agente", selection: $campos.agente) {
                        ForEach(AgenteNovoTerminal.allCases) { a in
                            Label(a.rotulo, systemImage: a.simbolo).tag(a)
                        }
                    }
                    .pickerStyle(.inline)
                }

                if let erro {
                    Section { Text(erro).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Novo terminal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Criar") { criar() }
                        .disabled(!NovoTerminalFormLogic.podeCriar(campos) || criando)
                }
            }
        }
        .onAppear {
            if campos.machine.isEmpty, let primeira = maquinas.first { campos.machine = primeira }
        }
    }

    private func criar() {
        criando = true
        erro = nil
        Task {
            do {
                let alvo = try await api.tmuxNewSession(machine: campos.machine,
                                                        group: campos.grupo,
                                                        session: campos.sessao,
                                                        cwd: campos.pasta,
                                                        agent: campos.agente.rawValue)
                aoCriar(campos.machine, alvo)
                dismiss()
            } catch {
                // Erro nomeia a máquina: "não deu" sem dizer onde é inútil quando
                // são três máquinas.
                erro = "não deu para criar em \(campos.machine): \(error.localizedDescription)"
            }
            criando = false
        }
    }
}

/// Navegação de pastas pela mesma fonte da aba Arquivos (`GET /machines/{m}/dirs`).
/// Só pastas: o alvo é o `-c` do `new-session`.
///
/// Desvio do plano (12/08/2026): `DirListing.dirs` é `[DirEntry]` (campos `name` e
/// `path`, este já absoluto), não `[String]` — ajustado ao tipo real de
/// `Models.swift` em vez do `d` cru que o plano assumia.
private struct SeletorDePasta: View {
    let machine: String
    @Binding var escolhida: String

    private let api = APIClient()
    @Environment(\.dismiss) private var dismiss
    @State private var atual = ""
    @State private var dirs: [DirEntry] = []
    @State private var carregando = false

    var body: some View {
        List {
            if !atual.isEmpty {
                Button {
                    atual = (atual as NSString).deletingLastPathComponent
                    Task { await carregar() }
                } label: {
                    Label("..", systemImage: "arrow.up.left")
                }
            }
            ForEach(dirs) { d in
                Button {
                    atual = d.path
                    Task { await carregar() }
                } label: {
                    Label(d.name, systemImage: "folder")
                }
            }
        }
        .overlay { if carregando { ProgressView() } }
        .navigationTitle(atual.isEmpty ? "Home" : (atual as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Usar esta") {
                    escolhida = atual
                    dismiss()
                }
                .disabled(atual.isEmpty)
            }
        }
        .task { await carregar() }
    }

    private func carregar() async {
        carregando = true
        // O listing do hub já devolve caminhos absolutos; se a chamada falhar, a
        // lista fica vazia e a Vanessa volta — sem alerta, porque navegar não é
        // destrutivo.
        if let listing = try? await api.listDirs(machine: machine, path: atual) {
            atual = listing.path
            dirs = listing.dirs.sorted { $0.name < $1.name }
        }
        carregando = false
    }
}
