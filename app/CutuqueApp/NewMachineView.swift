import SwiftUI
import UIKit

/// Cadastro de uma máquina nova na aba Máquinas, em três passos.
///
/// A ordem não é enfeite de UX, é a garantia de segurança do fluxo:
/// 1. **Dados** — o hub cadastra e gera o par de chaves. A privada nasce e
///    fica no macmini; o app nunca a vê.
/// 2. **Conferir** — a impressão digital do host aparece para a usuária
///    comparar com a máquina de verdade. Nada é confiado até ela dizer que
///    confere (TOFU).
/// 3. **Instalar** — só depois da confirmação a senha pode viajar: mandá-la
///    antes seria entregá-la a quem estivesse no meio. Instalar pelo hub é
///    opcional; quem preferir cola a chave pública na mão.
///
/// Fechar no meio não perde o cadastro: ele fica pendente na lista e a própria
/// lista oferece retomar (o hub relê a impressão pelo /scan).
struct NewMachineView: View {
    /// Cadastro já criado que ficou faltando confirmar. Vazio = máquina nova.
    let retomando: Machine?
    /// Avisa a lista para recarregar quando algo mudou de verdade.
    let onChanged: () -> Void

    init(retomando: Machine? = nil, onChanged: @escaping () -> Void) {
        self.retomando = retomando
        self.onChanged = onChanged
        if let retomando {
            _nome = State(initialValue: retomando.name)
            _dest = State(initialValue: retomando.dest)
            _porta = State(initialValue: String(retomando.port))
            _etapa = State(initialValue: .conferir)
        }
    }

    enum Etapa { case dados, conferir, instalar }

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    @State private var nome = ""
    @State private var dest = ""
    @State private var porta = "22"
    @State private var etapa: Etapa = .dados

    @State private var fingerprint = ""
    @State private var chavePublica = ""
    @State private var senha = ""

    @State private var trabalhando = false
    @State private var erro: String?
    /// Marca que já houve mudança no hub — fechar tem que avisar a lista mesmo
    /// se o fluxo não chegou ao fim.
    @State private var mexeuNoHub = false

    var body: some View {
        NavigationStack {
            Form {
                switch etapa {
                case .dados:    secaoDados
                case .conferir: secaoConferir
                case .instalar: secaoInstalar
                }
                if let erro {
                    Section {
                        Label(erro, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(retomando == nil ? "Nova máquina" : "Confirmar máquina")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { fechar() }
                }
            }
            .disabled(trabalhando)
            .overlay { if trabalhando { ProgressView() } }
            .task { if retomando != nil && fingerprint.isEmpty { await relerImpressao() } }
        }
    }

    // MARK: - Passo 1: dados

    @ViewBuilder private var secaoDados: some View {
        Section {
            TextField("Nome", text: $nome)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Destino (user@host)", text: $dest)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Porta", text: $porta)
                .keyboardType(.numberPad)
        } header: {
            Text("Máquina")
        } footer: {
            Text("O nome identifica a máquina no Cutuque e vira o nome do arquivo da chave — letras, números, `-` e `_`.")
        }

        Section {
            Button("Cadastrar") { Task { await cadastrar() } }
                .disabled(!dadosValidos)
        } footer: {
            Text("O hub gera um par de chaves só desta máquina. A parte privada fica no hub e não sai de lá.")
        }
    }

    private var dadosValidos: Bool {
        !nome.trimmingCharacters(in: .whitespaces).isEmpty
            && !dest.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(porta) != nil
    }

    // MARK: - Passo 2: conferir a impressão digital

    @ViewBuilder private var secaoConferir: some View {
        Section {
            Text(fingerprint.isEmpty ? "—" : fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } header: {
            Text("Impressão digital do host")
        } footer: {
            Text("Confira na própria máquina antes de aceitar:\n`ssh-keyscan -p \(porta) \(hostDoDest) | ssh-keygen -lf -`\n\nSe não bater, alguém pode estar no meio da conexão.")
        }

        Section {
            Button("Confere, pode confiar") { Task { await confiar() } }
                .disabled(fingerprint.isEmpty)
            Button("Não é essa — apagar cadastro", role: .destructive) {
                Task { await apagar() }
            }
        }
    }

    /// Só o host do destino, sem o usuário — é o que o `ssh-keyscan` quer.
    private var hostDoDest: String {
        dest.split(separator: "@").last.map(String.init) ?? dest
    }

    // MARK: - Passo 3: instalar a chave

    @ViewBuilder private var secaoInstalar: some View {
        Section {
            if chavePublica.isEmpty {
                Text("A chave foi gerada num cadastro anterior. Instale-a com a senha abaixo, ou pelo destino, se já tiver feito isso.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(chavePublica)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button {
                    UIPasteboard.general.string = chavePublica
                } label: {
                    Label("Copiar chave pública", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Chave pública do Cutuque")
        } footer: {
            Text("Cole no `~/.ssh/authorized_keys` da máquina — ou deixe o hub instalar com a senha abaixo.")
        }

        Section {
            SecureField("Senha da máquina", text: $senha)
                .textInputAutocapitalization(.never)
            Button("Instalar pelo hub") { Task { await instalar() } }
                .disabled(senha.isEmpty)
        } footer: {
            Text("Usada uma única vez, agora, para gravar a chave no destino. Não é guardada nem no app nem no hub.")
        }

        Section {
            Button("Terminar") { fechar() }
        } footer: {
            Text("A máquina já está confirmada e aparece na lista. Se a chave ainda não estiver instalada, a conexão vai falhar até você instalá-la.")
        }
    }

    // MARK: - Ações

    private func cadastrar() async {
        await executando {
            let criada = try await api.createMachine(
                name: nome.trimmingCharacters(in: .whitespaces),
                dest: dest.trimmingCharacters(in: .whitespaces),
                port: Int(porta) ?? 22
            )
            mexeuNoHub = true
            chavePublica = criada.publicKey
            fingerprint = criada.fingerprint
            etapa = .conferir
        }
    }

    private func relerImpressao() async {
        await executando { fingerprint = try await api.scanMachine(name: nome) }
    }

    private func confiar() async {
        await executando {
            try await api.trustMachine(name: nome, fingerprint: fingerprint)
            mexeuNoHub = true
            etapa = .instalar
        }
    }

    private func instalar() async {
        await executando {
            try await api.installKey(name: nome, password: senha)
            // A senha sai da memória do app assim que serve.
            senha = ""
            fechar()
        }
    }

    private func apagar() async {
        await executando {
            try await api.deleteMachine(name: nome)
            mexeuNoHub = true
            fechar()
        }
    }

    /// Roda a ação marcando o estado de trabalho e traduzindo o erro. Uma falha
    /// não avança de etapa: o erro fica na tela e a usuária tenta de novo.
    private func executando(_ acao: @escaping () async throws -> Void) async {
        trabalhando = true
        erro = nil
        defer { trabalhando = false }
        do {
            try await acao()
        } catch {
            erro = error.localizedDescription
        }
    }

    private func fechar() {
        if mexeuNoHub { onChanged() }
        dismiss()
    }
}
