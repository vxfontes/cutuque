import SwiftUI

/// Cadastro de máquina — página única, ao estilo Termius: host (nome, endereço,
/// porta) e identidade (usuário, chave, senha) são objetos separados desde o
/// redesenho do modelo. O antigo assistente de 3 passos (`enum Etapa`) foi
/// jogado fora: os passos que ainda precisam de decisão da usuária (confirmar
/// a impressão digital, digitar senha) viram seções/sheets condicionais na
/// MESMA tela, guiados por `Fase`.
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
            _host = State(initialValue: retomando.host ?? "")
            _porta = State(initialValue: String(retomando.port == 0 ? 22 : retomando.port))
            _tema = State(initialValue: retomando.theme ?? "")
            // Já existe no hub — os campos de host/identidade/tema ficam
            // travados; só falta terminar o que ficou pendente.
            _mexeuNoHub = State(initialValue: true)
            // Máquina com fingerprint já confirmado não deve pedir confirmação
            // de novo: reconfirmar sem motivo ensinaria a usuária a clicar
            // "confiar" no automático — o hábito que o TOFU existe pra evitar.
            let jaConfiada = !(retomando.hostFingerprint ?? "").isEmpty
            _fase = State(initialValue: jaConfiada ? .confiada : .formulario)
        }
    }

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    // Dados do host
    @State private var nome = ""
    @State private var host = ""
    @State private var porta = "22"
    @State private var tema = ""

    // Identidade escolhida (objeto cheio, não só o nome — precisa de
    // `hasPassword` na hora de decidir se o install-key pede senha).
    @State private var identidade: Identity?
    private struct IdentitySheetTrigger: Identifiable { let id = "identidade" }
    @State private var identitySheetTrigger: IdentitySheetTrigger?

    /// Sequência do check: cadastro/releitura → confirmar impressão → confiar
    /// → instalar chave (com ou sem pedir senha) → detectar SO → concluído.
    /// Enum simples (sem valor associado) pra toda comparação ficar trivial —
    /// o fingerprint conhecido e afins vivem em `@State` à parte.
    private enum Fase: Equatable { case formulario, pendenteDeConfirmar, confiada, pedindoSenha, concluido }
    @State private var fase: Fase = .formulario

    @State private var fingerprintConhecido: String?
    private struct FingerprintPendente: Identifiable { let fingerprint: String; var id: String { fingerprint } }
    @State private var fingerprintPendente: FingerprintPendente?

    @State private var podeGuardarSenha = false
    @State private var senha = ""
    @State private var guardarSenha = false
    @State private var avisoSO: String?
    @State private var avisoSenha: String?

    @State private var trabalhando = false
    @State private var erro: String?
    /// Verdadeiro assim que alguma chamada mudou algo no hub (criar, confiar,
    /// instalar, apagar) — a lista só precisa recarregar se algo mudou de
    /// verdade.
    @State private var mexeuNoHub = false

    var body: some View {
        NavigationStack {
            Form {
                secaoHost
                secaoIdentidade
                secaoTema

                if fase == .pedindoSenha { secaoSenha }

                if let avisoSO {
                    Section {
                        Label(avisoSO, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if let avisoSenha {
                    Section {
                        Label(avisoSenha, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if let erro {
                    Section {
                        Label(erro, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                if mexeuNoHub && fase != .concluido {
                    Section {
                        Button("Apagar cadastro pendente", role: .destructive) {
                            Task { await apagar() }
                        }
                    } footer: {
                        Text("Remove o cadastro e a chave do hub. Use se desistiu ou errou algo.")
                    }
                }
                if fase == .concluido {
                    Section {
                        Label("Máquina cadastrada e pronta.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Concluir") { fechar() }
                    }
                }
            }
            .navigationTitle(retomando == nil ? "Nova máquina" : "Confirmar máquina")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { fechar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onCheckTapped() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(checkDesabilitado)
                }
            }
            .disabled(trabalhando)
            .overlay { if trabalhando { ProgressView() } }
            .task { await preparar() }
            .sheet(item: $fingerprintPendente) { pendente in
                ConfirmarImpressaoView(
                    fingerprint: pendente.fingerprint,
                    host: host.trimmingCharacters(in: .whitespaces),
                    porta: porta,
                    onConfiar: {
                        fingerprintPendente = nil
                        Task { await confiarEContinuar(pendente.fingerprint) }
                    },
                    onApagar: {
                        fingerprintPendente = nil
                        Task { await apagar() }
                    }
                )
            }
            .sheet(item: $identitySheetTrigger) { _ in
                IdentitySheet(identidadeAtual: identidade) { escolhida in
                    identidade = escolhida
                }
            }
        }
    }

    // MARK: - Seções

    @ViewBuilder private var secaoHost: some View {
        Section {
            TextField("Nome", text: $nome)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Hostname ou IP", text: $host)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Porta", text: $porta)
                .keyboardType(.numberPad)
        } header: {
            Text("Host")
        } footer: {
            Text("O nome identifica a máquina no Cutuque — letras, números, `-` e `_`.")
        }
        .disabled(mexeuNoHub)
    }

    @ViewBuilder private var secaoIdentidade: some View {
        Section {
            Button {
                identitySheetTrigger = IdentitySheetTrigger()
            } label: {
                HStack {
                    if let identidade {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identidade.name).foregroundStyle(.primary)
                            Text(identidade.username).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Escolher identidade").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Credenciais")
        }
        .disabled(mexeuNoHub)
    }

    @ViewBuilder private var secaoTema: some View {
        Section {
            TerminalThemePicker(selection: $tema)
                .frame(minHeight: 220) // o picker é um ScrollView sem altura própria
        } header: {
            Text("Tema do terminal")
        }
        .disabled(mexeuNoHub)
    }

    @ViewBuilder private var secaoSenha: some View {
        Section {
            SecureField("Senha da máquina", text: $senha)
                .textInputAutocapitalization(.never)
            if podeGuardarSenha {
                Toggle("Guardar essa senha na identidade", isOn: $guardarSenha)
            }
            Button("Instalar") { Task { await instalarComSenhaDigitada() } }
                .disabled(senha.isEmpty)
        } header: {
            Text("Instalar chave")
        } footer: {
            Text(podeGuardarSenha
                ? "Usada uma única vez para gravar a chave no destino. Guardar evita digitar de novo num próximo host da mesma conta — fica cifrada no hub."
                : "Usada uma única vez, agora, para gravar a chave no destino. Não é guardada nem no app nem no hub.")
        }
    }

    // MARK: - Validação

    private var camposValidos: Bool {
        !nome.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(porta) != nil
            && identidade != nil
    }

    /// Fora do `.formulario` os campos já estão travados (cadastro existente),
    /// então `camposValidos` só se aplica ao cadastro do zero.
    private var checkDesabilitado: Bool {
        if trabalhando { return true }
        switch fase {
        case .pedindoSenha, .concluido:       return true
        case .formulario:                     return retomando == nil && !camposValidos
        case .pendenteDeConfirmar, .confiada: return false
        }
    }

    // MARK: - Sequência (check → TOFU → trust → install-key → detect-os)

    private func preparar() async {
        guard let retomando else { return }
        // Trava o ✓ ANTES do primeiro await. `listIdentities()` é um round-trip
        // de rede, e nesta janela `checkDesabilitado` devolvia `false` — o botão
        // ficava tocável. Um toque ali disparava scan/install-key EM PARALELO com
        // o que este `preparar` ia disparar logo abaixo, e o `defer` do primeiro
        // `executando` a terminar destravava a tela (inclusive "Apagar cadastro
        // pendente") com a outra chamada ainda em voo.
        //
        // Não solto a trava antes do `switch`: `await executando` é ponto de
        // suspensão, então liberar aqui reabriria a mesma janela, menor.
        // Quem solta é o `defer` de dentro do `executando`.
        trabalhando = true
        // Resolve o objeto Identity cheio a partir do nome — o cadastro
        // pendente só guarda o nome; sem isso não saberíamos `hasPassword` na
        // hora de decidir se o install-key pede senha.
        if let nomeIdentidade = retomando.identity, !nomeIdentidade.isEmpty,
           let resp = try? await api.listIdentities() {
            identidade = resp.identities.first { $0.name == nomeIdentidade }
        }
        switch fase {
        case .confiada:
            // Fingerprint já confirmado num cadastro anterior — pula scan e
            // trust de novo, vai direto para instalar a chave.
            await executando { try await avancarParaInstalacao() }
        case .formulario where fingerprintConhecido == nil:
            // Retomando sem fingerprint ainda: relê e já mostra a confirmação,
            // sem exigir mais um toque (paridade com o assistente antigo).
            await executando {
                let fp = try await api.scanMachine(name: retomando.name)
                fingerprintConhecido = fp
                fase = .pendenteDeConfirmar
                fingerprintPendente = FingerprintPendente(fingerprint: fp)
            }
        default:
            // Nada a disparar: este é o único ramo que não delega pro
            // `executando`, então é ele que solta a trava tomada acima.
            trabalhando = false
        }
    }

    private func onCheckTapped() async {
        switch fase {
        case .formulario:
            if let retomando {
                // Releitura automática falhou (host fora do ar etc.) — tenta de
                // novo; NÃO recadastra (a máquina já existe).
                await executando {
                    let fp = try await api.scanMachine(name: retomando.name)
                    fingerprintConhecido = fp
                    fase = .pendenteDeConfirmar
                    fingerprintPendente = FingerprintPendente(fingerprint: fp)
                }
            } else {
                await executando {
                    let criada = try await api.createMachine(
                        name: nome.trimmingCharacters(in: .whitespaces),
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: Int(porta) ?? 22,
                        identity: identidade?.name ?? "",
                        theme: tema
                    )
                    mexeuNoHub = true
                    fingerprintConhecido = criada.fingerprint
                    fase = .pendenteDeConfirmar
                    fingerprintPendente = FingerprintPendente(fingerprint: criada.fingerprint)
                }
            }
        case .pendenteDeConfirmar:
            // Sheet fechada sem decisão (swipe) — reabre com o mesmo
            // fingerprint, sem nova chamada de rede.
            if let fp = fingerprintConhecido {
                fingerprintPendente = FingerprintPendente(fingerprint: fp)
            }
        case .confiada:
            await executando { try await avancarParaInstalacao() }
        case .pedindoSenha, .concluido:
            break // botão fica desabilitado nesses casos
        }
    }

    private func confiarEContinuar(_ fp: String) async {
        await executando {
            try await api.trustMachine(name: nome, fingerprint: fp)
            fase = .confiada
            mexeuNoHub = true
            try await avancarParaInstalacao()
        }
    }

    private func avancarParaInstalacao() async throws {
        if identidade?.hasPassword == true {
            do {
                try await api.installKey(name: nome, password: "")
                await concluirComDetectOS()
                return
            } catch let falha {
                // Senha guardada não serviu. SEM esta saída era beco sem saída:
                // o erro aparecia, a fase continuava `.confiada`, e o único
                // `SecureField` da tela é o do `.pedindoSenha` — então tocar o ✓
                // de novo reenviava a MESMA senha errada, pra sempre. Não é canto
                // raro: senha de host muda, e não existe outra tela no app pra
                // trocar a senha guardada de uma identidade.
                //
                // 409 (`not_trusted`) é a exceção: não é problema de senha, é o
                // TOFU (o `known_hosts` do hub não tem mais este host). Pedir
                // senha aqui mandaria a usuária consertar a coisa errada, então
                // o erro sobe e a fase volta pro início, onde o ✓ relê e
                // reconfirma o fingerprint.
                if let cutuque = falha as? CutuqueError, case .server(409, _) = cutuque {
                    fase = .formulario
                    fingerprintConhecido = nil
                    throw falha
                }
                avisoSenha = "A senha guardada nesta identidade não funcionou (\(falha.localizedDescription)). Digite a senha atual — deixe \"guardar\" marcado para substituir a antiga."
                guardarSenha = true
            }
        }
        // Só pra saber se oferece o toggle de guardar — não bloqueia o
        // pedido de senha se essa checagem falhar.
        podeGuardarSenha = (try? await api.listIdentities().canStorePassword) ?? false
        fase = .pedindoSenha
    }

    private func instalarComSenhaDigitada() async {
        guard fase == .pedindoSenha, !senha.isEmpty else { return }
        await executando {
            let senhaParaEnviar = senha
            senha = "" // sai da mão da usuária assim que capturada, nos dois usos abaixo
            try await api.installKey(name: nome, password: senhaParaEnviar)
            if guardarSenha {
                if let identidade {
                    do {
                        try await api.updateIdentity(name: identidade.name, username: identidade.username, password: senhaParaEnviar)
                    } catch {
                        // A chave já foi instalada — não desfaz o cadastro por causa disso.
                        avisoSenha = "A chave foi instalada, mas não deu para guardar a senha na identidade (\(error.localizedDescription))."
                    }
                } else {
                    // `identidade` só é nil se a resolução em `preparar()` falhou
                    // (rede fora naquele instante). Antes o `let` no meio do `if`
                    // fazia isso sumir em silêncio: a usuária marcava "guardar",
                    // a senha era instalada e NÃO era guardada, sem aviso — e ela
                    // só descobriria no próximo host, quando pedisse senha de novo.
                    avisoSenha = "A chave foi instalada, mas a senha não foi guardada: não deu para identificar a identidade deste cadastro. Reabra o cadastro para guardá-la."
                }
            }
            await concluirComDetectOS()
        }
    }

    private func concluirComDetectOS() async {
        // Não fatal: o SO só decide o ícone da lista.
        do {
            _ = try await api.detectOS(name: nome)
        } catch {
            avisoSO = "Não deu para detectar o sistema — a máquina foi cadastrada normalmente, só o ícone fica genérico."
        }
        mexeuNoHub = true
        fase = .concluido
    }

    private func apagar() async {
        await executando {
            try await api.deleteMachine(name: nome)
            mexeuNoHub = true
            fechar()
        }
    }

    private func executando(_ acao: @escaping () async throws -> Void) async {
        trabalhando = true
        erro = nil
        defer { trabalhando = false }
        do { try await acao() } catch { erro = error.localizedDescription }
    }

    private func fechar() {
        if mexeuNoHub { onChanged() }
        dismiss()
    }
}

// MARK: - Confirmar impressão digital (TOFU)

/// TOFU explícito: a impressão digital aparece para a usuária comparar com a
/// máquina de verdade ANTES de qualquer coisa ser confiada — sem isso,
/// cadastrar host novo seria abrir a porta para MITM. Nunca auto-confirma.
private struct ConfirmarImpressaoView: View {
    let fingerprint: String
    let host: String
    let porta: String
    let onConfiar: () -> Void
    let onApagar: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Impressão digital do host")
                } footer: {
                    Text("Confira na própria máquina antes de aceitar:\nssh-keyscan -p \(porta) \(host) | ssh-keygen -lf -\n\nSe não bater, alguém pode estar no meio da conexão.")
                }
                Section {
                    Button("Confere, pode confiar") { onConfiar() }
                    Button("Não é essa — apagar cadastro", role: .destructive) { onApagar() }
                }
            }
            .navigationTitle("Confirmar host")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Sheet de identidades

/// Bottom sheet "escolher identidade": lista as existentes e, pelo `+`, empurra
/// a tela de criar uma nova. Editar/apagar identidade fica fora daqui de
/// propósito (fora do escopo deste redesenho) — só criar e escolher.
private struct IdentitySheet: View {
    let identidadeAtual: Identity?
    let onEscolhida: (Identity) -> Void

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    @State private var identidades: [Identity] = []
    @State private var podeGuardarSenha = false
    @State private var carregando = false
    @State private var erro: String?
    @State private var criandoNova = false

    var body: some View {
        NavigationStack {
            List {
                if let erro {
                    Section {
                        Label(erro, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                ForEach(identidades) { candidata in
                    Button {
                        onEscolhida(candidata)
                        dismiss()
                    } label: {
                        linha(candidata)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay { if carregando && identidades.isEmpty { ProgressView() } }
            .navigationTitle("Identidades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { criandoNova = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(isPresented: $criandoNova) {
                NovaIdentidadeView(podeGuardarSenha: podeGuardarSenha) { criada in
                    onEscolhida(criada)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await carregar() }
    }

    private func linha(_ candidata: Identity) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidata.name).foregroundStyle(.primary)
                Text("\(candidata.username) · \(candidata.hasPassword ? "senha guardada" : "só chave")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if candidata.id == identidadeAtual?.id {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
    }

    private func carregar() async {
        carregando = true
        defer { carregando = false }
        do {
            let resp = try await api.listIdentities()
            identidades = resp.identities
            podeGuardarSenha = resp.canStorePassword
        } catch {
            erro = error.localizedDescription
        }
    }
}

/// Tela "Nova identidade", empurrada pelo `+` do sheet de identidades. Campo de
/// senha só aparece se o hub aceitar guardar (`canStorePassword`) — sem isso a
/// identidade nasce só de chave.
private struct NovaIdentidadeView: View {
    let podeGuardarSenha: Bool
    let onCriada: (Identity) -> Void

    private let api = APIClient()

    @State private var nome = ""
    @State private var username = ""
    @State private var senha = ""
    @State private var criando = false
    @State private var erro: String?
    /// Chave pública recém-gerada, mostrada só quando a identidade nasce SEM
    /// senha. Nesse caso o hub não tem como instalar a chave sozinho (não há
    /// senha para autenticar o primeiro acesso), e colar esta linha no
    /// `authorized_keys` do host é o ÚNICO caminho de entrada — engolir a chave
    /// aqui deixava a identidade inutilizável sem nenhuma pista na tela.
    /// Com senha guardada não aparece: o `install-key` resolve sozinho.
    @State private var chaveParaInstalar: (identidade: Identity, publicKey: String)?

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $nome)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Usuário", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("O nome identifica a identidade no Cutuque; o usuário é o da conexão SSH.")
            }
            if podeGuardarSenha {
                Section {
                    SecureField("Senha (opcional)", text: $senha)
                } footer: {
                    Text("Fica guardada cifrada no hub. Em branco, a identidade usa só a chave.")
                }
            }
            if let erro {
                Section {
                    Label(erro, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }
            if let chaveParaInstalar {
                Section {
                    Text(chaveParaInstalar.publicKey)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    ShareLink(item: chaveParaInstalar.publicKey) {
                        Label("Compartilhar a chave", systemImage: "square.and.arrow.up")
                    }
                    Button("Continuar") { onCriada(chaveParaInstalar.identidade) }
                } header: {
                    Text("Chave pública de \(chaveParaInstalar.identidade.name)")
                } footer: {
                    Text("Identidade sem senha: o hub não consegue instalar a chave sozinho. Cole esta linha no `~/.ssh/authorized_keys` do host antes de fechar o cadastro. A chave privada fica no hub e não sai de lá.")
                }
            } else {
                Section {
                    Button("Criar identidade") { Task { await criar() } }
                        .disabled(nome.trimmingCharacters(in: .whitespaces).isEmpty
                            || username.trimmingCharacters(in: .whitespaces).isEmpty || criando)
                }
            }
        }
        .navigationTitle("Nova identidade")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(criando)
        .overlay { if criando { ProgressView() } }
    }

    private func criar() async {
        criando = true
        erro = nil
        defer { criando = false }
        do {
            let criada = try await api.createIdentity(
                name: nome.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces),
                password: podeGuardarSenha ? senha : ""
            )
            senha = "" // some da memória assim que serviu ao POST
            if criada.identity.hasPassword {
                onCriada(criada.identity) // hub instala a chave sozinho: segue o fluxo
            } else {
                chaveParaInstalar = (criada.identity, criada.publicKey)
            }
        } catch {
            erro = error.localizedDescription
        }
    }
}
