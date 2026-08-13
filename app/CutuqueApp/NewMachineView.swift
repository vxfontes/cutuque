import SwiftUI

/// Cadastro de máquina — página única, ao estilo Termius: host (nome, endereço,
/// porta) e identidade (usuário, chave, senha) são objetos separados desde o
/// redesenho do modelo. O antigo assistente de 3 passos (`enum Etapa`) foi
/// jogado fora: os passos que ainda precisam de decisão da usuária (confirmar
/// a impressão digital, digitar senha) viram seções/sheets condicionais na
/// MESMA tela, guiados por `Fase`.
struct NewMachineView: View {
    /// O que esta tela está fazendo com a máquina.
    ///
    /// `retomar` e `editar` partem da MESMA máquina já cadastrada, e a diferença
    /// entre elas é de premissa: retomando, o cadastro está certo e só faltou
    /// terminar (campos travados); editando, o cadastro é justamente o que está
    /// errado (campos abertos até o PATCH ir).
    enum Modo: Equatable, Identifiable {
        case nova
        case retomar(Machine)
        case editar(Machine)

        /// Serve de identidade da sheet: `retomar` e `editar` da mesma máquina
        /// são telas diferentes e não podem colidir no `id`.
        var id: String {
            switch self {
            case .nova:            return "nova"
            case .retomar(let m):  return "retomar:\(m.name)"
            case .editar(let m):   return "editar:\(m.name)"
            }
        }

        /// A máquina que já existe no hub, quando existe.
        var machine: Machine? {
            switch self {
            case .nova:                             return nil
            case .retomar(let m), .editar(let m):   return m
            }
        }

        var editando: Bool {
            if case .editar = self { return true }
            return false
        }
    }

    /// O que mandar para `PUT /machines/{n}/appearance` ao salvar a edição, ou
    /// `nil` se nada mudou (não gastar pedido nem sobrescrever com igual).
    struct Aparencia: Equatable {
        let tema: String
        let icone: String

        static func decidir(temaAtual: String, iconeAtual: String,
                            temaEscolhido: String, iconeEscolhido: String) -> Aparencia? {
            guard temaEscolhido != temaAtual || iconeEscolhido != iconeAtual else { return nil }
            return Aparencia(tema: temaEscolhido, icone: iconeEscolhido)
        }
    }

    let modo: Modo
    /// Avisa a lista para recarregar quando algo mudou de verdade.
    let onChanged: () -> Void

    init(modo: Modo = .nova, onChanged: @escaping () -> Void) {
        self.modo = modo
        self.onChanged = onChanged
        guard let existente = modo.machine else { return }
        _nome = State(initialValue: existente.name)
        _host = State(initialValue: existente.host ?? "")
        _porta = State(initialValue: String(existente.port == 0 ? 22 : existente.port))
        _tema = State(initialValue: existente.theme ?? "")
        _icone = State(initialValue: existente.icon ?? "")
        if modo.editando {
            // Editando, os campos nascem ABERTOS — travar aqui seria travar
            // exatamente o que a usuária veio mudar. E `mexeuNoHub` fica falso:
            // até o PATCH ir, esta tela não mudou nada lá.
            _fase = State(initialValue: .formulario)
        } else {
            // Já existe no hub — os campos de host/identidade/tema ficam
            // travados; só falta terminar o que ficou pendente.
            _camposTravados = State(initialValue: true)
            _mexeuNoHub = State(initialValue: true)
            // Máquina com fingerprint já confirmado não deve pedir confirmação
            // de novo: reconfirmar sem motivo ensinaria a usuária a clicar
            // "confiar" no automático — o hábito que o TOFU existe pra evitar.
            let jaConfiada = !(existente.hostFingerprint ?? "").isEmpty
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
    /// `""` = automático. Só existe estado próprio porque, ao editar, o ícone
    /// vai junto do tema no MESMO `PUT /appearance` — ver `secaoAparencia`.
    @State private var icone = ""

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
    /// Host, identidade e tema abertos ou travados. Cadastro novo: abertos até o
    /// POST. Retomando: travados desde o começo. Editando: abertos até o PATCH.
    ///
    /// Era o próprio `mexeuNoHub` que travava os campos, e as duas coisas
    /// coincidiam enquanto só havia cadastrar e retomar. Editar separou: ali os
    /// campos precisam abrir com a máquina JÁ existindo no hub.
    @State private var camposTravados = false
    /// Recusei a impressão digital editando: o endereço novo ficou salvo sem
    /// confiança. Aviso, não erro — o estado é recuperável e a lista o mostra.
    @State private var avisoEdicao: String?

    var body: some View {
        NavigationStack {
            Form {
                secaoHost
                secaoIdentidade
                // [13/08/2026] Editando, aparência agora vem — pedido da
                // Vanessa ("a parte de personalizar a maquina não deixa
                // escolher as coisas do hub tipo icone, tema e tal"), e ela
                // pediu nos DOIS lugares (aqui e na sheet Informações). O
                // `PATCH` continua mandando `theme: ""` (= mantém) porque
                // continua não sabendo expressar "volta ao padrão": quem leva
                // aparência é o `PUT /appearance`, chamado no salvar (ver
                // `salvarEdicao`). Cadastrando, segue só o tema pelo POST —
                // máquina que ainda não existe não tem `/appearance` para
                // chamar (era a assimetria que o comentário antigo
                // registrava, e continua valendo pro cadastro).
                if modo.editando { secaoAparencia } else { secaoTema }

                if fase == .pedindoSenha { secaoSenha }

                if let avisoEdicao {
                    Section {
                        Label(avisoEdicao, systemImage: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
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
                // Editando NÃO oferece apagar: quem entrou aqui veio corrigir um
                // endereço, não descadastrar a máquina — e apagar é o único
                // botão desta tela que não tem volta.
                if mexeuNoHub && fase != .concluido && !modo.editando {
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
                        Label(modo.editando ? "Máquina atualizada." : "Máquina cadastrada e pronta.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Concluir") { fechar() }
                    }
                }
            }
            .navigationTitle(titulo)
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
                    // Editando, recusar NÃO apaga: a máquina já existia antes
                    // desta tela e continua existindo depois dela.
                    rotuloRecusa: modo.editando ? "Não é essa — parar aqui" : "Não é essa — apagar cadastro",
                    onConfiar: {
                        fingerprintPendente = nil
                        Task { await confiarEContinuar(pendente.fingerprint) }
                    },
                    onRecusar: {
                        fingerprintPendente = nil
                        if modo.editando {
                            avisoEdicao = "O endereço novo ficou salvo, mas sem confirmação: a máquina aparece na lista pedindo conferência e não conecta até isso. Edite de novo se o endereço estiver errado."
                        } else {
                            Task { await apagar() }
                        }
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

    private var titulo: String {
        switch modo {
        case .nova:     return "Nova máquina"
        case .retomar:  return "Confirmar máquina"
        case .editar:   return "Editar máquina"
        }
    }

    @ViewBuilder private var secaoHost: some View {
        Section {
            TextField("Nome", text: $nome)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                // O nome não se edita nunca: é a chave do cadastro no hub, do
                // painel lembrado por host e da sessão de terminal aberta —
                // trocá-lo seria criar outra máquina com cara da mesma.
                .disabled(modo.editando)
            TextField("Hostname ou IP", text: $host)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Porta", text: $porta)
                .keyboardType(.numberPad)
        } header: {
            Text("Host")
        } footer: {
            Text(modo.editando
                ? "O nome não muda: é por ele que o hub, as sessões abertas e as preferências deste host se encontram. Trocar endereço ou porta pede a impressão digital de novo."
                : "O nome identifica a máquina no Cutuque — letras, números, `-` e `_`.")
        }
        .disabled(camposTravados)
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
                    } else if let nomeAtual = modo.machine?.identity, !nomeAtual.isEmpty {
                        // A máquina TEM identidade, só não deu para carregar o
                        // objeto dela (rede fora no `preparar`). "Escolher
                        // identidade" aqui diria que ela está sem — e o ✓ manda
                        // `""`, que o hub lê como "mantém": nada se perde, mas a
                        // tela não pode mentir sobre isso.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(nomeAtual).foregroundStyle(.primary)
                            Text("não deu para carregar os dados desta identidade")
                                .font(.caption).foregroundStyle(.orange)
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
        } footer: {
            if modo.editando {
                // [13/08/2026] Perdeu o "tema e ícone ficam em Informações":
                // desde que `secaoAparencia` existe, as duas aparecem AQUI
                // também (a sheet Informações continua tendo — são os dois
                // lugares que a Vanessa pediu, não um só).
                Text("Trocar de identidade instala a chave da nova no destino.")
            }
        }
        .disabled(camposTravados)
    }

    @ViewBuilder private var secaoTema: some View {
        Section {
            TerminalThemePicker(selection: $tema)
                .frame(minHeight: 220) // o picker é um ScrollView sem altura própria
        } header: {
            Text("Tema do terminal")
        }
        .disabled(camposTravados)
    }

    /// Ícone + tema ao EDITAR — item 4 do apontamento dela. Usa o MESMO
    /// `SeletorDeIconeDeMaquina` e `TerminalThemePicker` que a sheet
    /// Informações já usa: duplicar a grade à mão aqui divergiria da sheet na
    /// primeira mexida em qualquer uma das duas.
    ///
    /// Ao contrário de `secaoTema` (só cadastro), esta seção não escreve nada
    /// sozinha — só junta `tema`/`icone` no `@State`. Quem manda ao hub é
    /// `salvarEdicao`, e só se `Aparencia.decidir` disser que mudou algo.
    @ViewBuilder private var secaoAparencia: some View {
        Section {
            SeletorDeIconeDeMaquina(so: modo.machine?.os, escolhido: icone, habilitado: !camposTravados) {
                icone = $0
            }
        } header: {
            Text("Ícone")
        } footer: {
            Text("Automático usa o sistema detectado.")
        }
        Section {
            TerminalThemePicker(selection: $tema)
                .frame(minHeight: 220) // o picker é um ScrollView sem altura própria
        } header: {
            Text("Tema do terminal")
        } footer: {
            Text("Vale só para esta máquina, e o terminal aberto muda de cor na hora.")
        }
        .disabled(camposTravados)
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

    /// A porta digitada, ou `nil` se não serve para conectar.
    ///
    /// O teto é o do TCP. O hub recusa acima dele — e faz certo —, mas recusa
    /// depois do toque; validar aqui é o que transforma "70000" num ✓ apagado em
    /// vez de num erro vindo da rede. `0` também não passa: o hub trata porta
    /// zero como "não informada" e a rebaixaria para 22 calado, o que não é o que
    /// quem digitou zero pediu. Apara espaço porque valor colado costuma vir com
    /// um na frente.
    static func portaValida(_ texto: String) -> Int? {
        guard let n = Int(texto.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(n) else { return nil }
        return n
    }

    private var camposValidos: Bool {
        !nome.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && Self.portaValida(porta) != nil
            && identidade != nil
    }

    /// Editando, a identidade pode ficar como está: `""` no PATCH significa
    /// "mantém", e exigi-la aqui travaria o ✓ justamente quando a resolução do
    /// objeto `Identity` falhou por rede — com o endereço, que é o que a usuária
    /// veio corrigir, já digitado.
    private var conexaoValida: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Self.portaValida(porta) != nil
    }

    /// Fora do `.formulario` os campos já estão travados (cadastro existente),
    /// então `camposValidos` só se aplica ao cadastro do zero.
    private var checkDesabilitado: Bool {
        if trabalhando { return true }
        switch fase {
        case .pedindoSenha, .concluido:
            return true
        case .formulario:
            // Editando: enquanto os campos estão abertos o ✓ salva (precisa de
            // endereço válido); travados, ele repete o scan que falhou.
            if modo.editando { return camposTravados ? false : !conexaoValida }
            return modo.machine == nil && !camposValidos
        case .pendenteDeConfirmar, .confiada:
            return false
        }
    }

    // MARK: - Sequência (check → TOFU → trust → install-key → detect-os)

    private func preparar() async {
        guard let existente = modo.machine else { return }
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
        if let nomeIdentidade = existente.identity, !nomeIdentidade.isEmpty,
           let resp = try? await api.listIdentities() {
            identidade = resp.identities.first { $0.name == nomeIdentidade }
        }
        if modo.editando {
            // Editando não dispara nada sozinho: a usuária ainda vai mexer nos
            // campos, e um scan aqui pediria confirmação do endereço ANTIGO.
            trabalhando = false
            return
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
                let fp = try await api.scanMachine(name: existente.name)
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
            if modo.editando && !camposTravados {
                await executando { try await salvarEdicao() }
            } else if let existente = modo.machine {
                // Releitura automática falhou (host fora do ar etc.) — tenta de
                // novo; NÃO recadastra (a máquina já existe). Serve às duas: a
                // retomada e a edição cujo scan pós-PATCH não passou.
                await executando {
                    let fp = try await api.scanMachine(name: existente.name)
                    fingerprintConhecido = fp
                    fase = .pendenteDeConfirmar
                    fingerprintPendente = FingerprintPendente(fingerprint: fp)
                }
            } else {
                await executando {
                    let criada = try await api.createMachine(
                        name: nome.trimmingCharacters(in: .whitespaces),
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: Self.portaValida(porta) ?? 22,
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

    /// Salva a edição do host e retoma a sequência de onde a mudança exige.
    ///
    /// O que decide o próximo passo é a RESPOSTA do hub, não o que foi digitado:
    /// mudar endereço ou porta faz o hub jogar fora a impressão digital (e o SO
    /// detectado), e a máquina volta como `needsTrust` — daí o TOFU inteiro de
    /// novo, que é o ponto: endereço novo é host novo até alguém conferir.
    /// Endereço igual e identidade outra mantém a confiança no host, mas a chave
    /// da identidade nova pode não estar no destino — instala.
    private func salvarEdicao() async throws {
        guard let atual = modo.machine else { return }
        let novaIdentidade = identidade?.name ?? ""
        let atualizada = try await api.updateMachine(
            name: atual.name,
            host: host.trimmingCharacters(in: .whitespaces),
            // Cai no valor atual e não em 22: campo ilegível não é motivo pra
            // rebaixar a porta de ninguém (o ✓ já exige uma válida).
            port: Self.portaValida(porta) ?? atual.port,
            identity: novaIdentidade,
            // [13/08/2026] Vazio = mantém, e isso continua valendo: o PATCH
            // nunca soube expressar "volta ao padrão" (e não tem campo de
            // ícone nenhum). O que mudou é que esta tela AGORA manda
            // aparência de verdade — só que pelo PUT /appearance logo abaixo,
            // que sabe dizer isso.
            theme: ""
        )
        mexeuNoHub = true
        camposTravados = true
        // Depois dos campos, a aparência — nessa ordem, e só quando
        // `Aparencia.decidir` (abaixo) diz que tema ou ícone realmente
        // mudaram: não vale a pena gastar um PUT nem sobrescrever com o
        // mesmo valor que já estava lá.
        if let alvo = Aparencia.decidir(temaAtual: atual.theme ?? "", iconeAtual: atual.icon ?? "",
                                        temaEscolhido: tema, iconeEscolhido: icone) {
            _ = try await api.setAppearance(name: atual.name, theme: alvo.tema, icon: alvo.icone)
        }
        if atualizada.needsTrust {
            let fp = try await api.scanMachine(name: atual.name)
            fingerprintConhecido = fp
            fase = .pendenteDeConfirmar
            fingerprintPendente = FingerprintPendente(fingerprint: fp)
        } else if !novaIdentidade.isEmpty && novaIdentidade != (atual.identity ?? "") {
            fase = .confiada
            try await avancarParaInstalacao()
        } else {
            // Nada que mexa em conexão — ou nada mesmo (✓ sem ter editado).
            fase = .concluido
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
    /// O que a recusa faz depende de quem chamou: apagar o cadastro pendente
    /// (máquina nova, que só existe por causa desta tela) ou apenas parar
    /// (editando uma máquina que já existia antes e continua existindo).
    let rotuloRecusa: String
    let onConfiar: () -> Void
    let onRecusar: () -> Void

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
                    Button(rotuloRecusa, role: .destructive) { onRecusar() }
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
    // [13/08/2026] `Color.accentColor` ignora o `.tint()` da raiz (resolve do
    // catálogo de assets, que este app nem tem) — era por isso que o ✓ desta
    // lista ficava azul mesmo com outro tema escolhido em Ajustes.
    @Environment(\.corDeDestaque) private var corDeDestaque
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
                Image(systemName: "checkmark").foregroundStyle(corDeDestaque)
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
