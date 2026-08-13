import SwiftUI

/// Informações de uma máquina já cadastrada, mais o que dá para trocar sem
/// reconectar: tema do terminal e ícone.
///
/// O que NÃO se edita aqui é de propósito: host, porta e identidade mudam a
/// conexão (e o host derruba a impressão digital confirmada), então moram na tela
/// de edição, que sabe re-disparar a confirmação. Aqui é só aparência —
/// `PUT /machines/{n}/appearance` não tem como encostar em fingerprint.
///
/// **O tema volta pelo `Binding`, não recarregando a máquina.** No iPad o painel
/// de detalhe é identificado pela máquina selecionada; reescrever a seleção com
/// uma `Machine` de tema novo destruiria a view, fechando o WebSocket e matando o
/// `ssh` vivo do outro lado. Então quem manda o tema para o terminal é o `@State`
/// da tela de detalhe, e a lista relê do hub quando reabre.
struct MachineInfoSheet: View {
    /// Máquina como a lista a conhece. Serve de ponto de partida e de fonte das
    /// informações; a aparência viva mora nos bindings.
    let machine: Machine
    @Binding var tema: String
    @Binding var icone: String
    /// Avisa a lista para recarregar — o hub já tem o valor novo.
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let api = APIClient()

    /// SO detectado, que muda aqui mesmo quando ela pede para detectar de novo.
    @State private var so: String?
    @State private var detectando = false
    @State private var erro: String?
    @State private var avisoSO: String?

    /// Quem fala com o hub sobre aparência, um pedido de cada vez.
    @StateObject private var escrita: EscritorDeAparencia

    init(machine: Machine, tema: Binding<String>, icone: Binding<String>, onChanged: @escaping () -> Void) {
        self.machine = machine
        _tema = tema
        _icone = icone
        self.onChanged = onChanged
        _so = State(initialValue: machine.os)
        let cliente = APIClient()
        let nome = machine.name
        _escrita = StateObject(wrappedValue: EscritorDeAparencia(
            confirmada: AparenciaDaMaquina(tema: tema.wrappedValue, icone: icone.wrappedValue),
            enviar: { alvo in
                _ = try await cliente.setAppearance(name: nome, theme: alvo.tema, icon: alvo.icone)
            }))
    }

    var body: some View {
        NavigationStack {
            Form {
                secaoInformacoes
                secaoIcone
                secaoTema
                if let avisoSO {
                    Section {
                        Label(avisoSO, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
                if let erro {
                    Section {
                        Label(erro, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle(machine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Sair no meio de um envio é permitido: o pedido segue, e se
                    // falhar o desfazer cai no mesmo `Binding` que a tela de
                    // detalhe usa — o terminal volta à cor certa com a sheet já
                    // fechada. Travar o Pronto só prenderia a usuária num hub lento.
                    Button("Pronto") { dismiss() }
                }
            }
        }
    }

    // MARK: - Seções

    @ViewBuilder private var secaoInformacoes: some View {
        Section {
            linha("Endereço", machine.displayDest)
            if let identidade = machine.identity, !identidade.isEmpty {
                linha("Identidade", identidade)
            }
            linha("Sistema", (so?.isEmpty == false) ? so! : "não detectado")
            linha("Origem", origem)
            if let fp = machine.hostFingerprint, !fp.isEmpty {
                // Monoespaçado e quebrando: é o dado que ela compara caractere a
                // caractere quando desconfia de algo.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Impressão digital").font(.caption).foregroundStyle(.secondary)
                    Text(fp).font(.footnote.monospaced()).textSelection(.enabled)
                }
            } else if machine.needsTrust {
                Label("Impressão digital não confirmada — esta máquina não conecta.",
                      systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange).font(.callout)
            }
            if machine.isEditable {
                Button {
                    Task { await detectarSO() }
                } label: {
                    HStack {
                        Text("Detectar sistema de novo")
                        if detectando { Spacer(); ProgressView() }
                    }
                }
                .disabled(detectando || machine.needsTrust)
            }
        } header: {
            Text("Informações")
        } footer: {
            Text("Endereço, porta e identidade mudam em Editar, arrastando a máquina para a direita na lista — trocar o endereço faz conferir a impressão digital de novo.")
        }
    }

    @ViewBuilder private var secaoIcone: some View {
        Section {
            // A grade mora em `SeletorDeIconeDeMaquina` desde 13/08/2026: o
            // formulário de máquina usa a mesma.
            SeletorDeIconeDeMaquina(so: so, escolhido: icone, habilitado: machine.isEditable) { id in
                aplicar(tema: tema, icone: id)
            }
        } header: {
            HStack {
                Text("Ícone")
                if escrita.enviando {
                    Spacer()
                    // Só sinal de que o pedido está a caminho: a grade continua
                    // clicável de propósito, e o último toque é o que vale.
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            Text("Automático usa o sistema detectado. Escolher à mão resolve o host onde a detecção não funciona.")
        }
        .disabled(!machine.isEditable)
    }

    @ViewBuilder private var secaoTema: some View {
        Section {
            TerminalThemePicker(selection: Binding(get: { tema }, set: { escolhido in
                aplicar(tema: escolhido, icone: icone)
            }))
            .frame(minHeight: 220) // o picker é um ScrollView sem altura própria
        } header: {
            Text("Tema do terminal")
        } footer: {
            Text(machine.isEditable
                 ? "Vale só para esta máquina, e o terminal aberto muda de cor na hora."
                 : "Máquina do hub.env: a aparência dela é do hub, não do app.")
        }
        .disabled(!machine.isEditable)
    }

    private func linha(_ rotulo: String, _ valor: String) -> some View {
        HStack {
            Text(rotulo).foregroundStyle(.secondary)
            Spacer()
            Text(valor).multilineTextAlignment(.trailing)
        }
    }

    private var origem: String {
        if machine.isLocal { return "o próprio hub" }
        return machine.isEditable ? "cadastrada no app" : "hub.env"
    }

    // MARK: - Ações

    /// Manda os DOIS campos sempre: a rota é PUT, substituição — mandar só um
    /// apagaria o outro. Aplica no `Binding` antes de a rede responder para o
    /// toque não parecer engasgado, e volta atrás se o hub recusar.
    ///
    /// A fila do `EscritorDeAparencia` é que garante um pedido em voo por vez; aqui
    /// fica só o que é de tela: mostrar na hora e desfazer se o hub recusar.
    private func aplicar(tema novoTema: String, icone novoIcone: String) {
        let alvo = AparenciaDaMaquina(tema: novoTema, icone: novoIcone)
        guard alvo != AparenciaDaMaquina(tema: tema, icone: icone) else { return }
        tema = alvo.tema
        icone = alvo.icone
        erro = nil
        Task {
            switch await escrita.aplicar(alvo) {
            case .gravou:
                onChanged()
            case .enfileirou:
                break // quem está enviando avisa a lista quando terminar
            case .falhou(let motivo):
                // Volta para o que o hub CONFIRMOU, não para o valor de antes
                // deste toque — com toques em sequência os dois não são o mesmo.
                tema = escrita.confirmada.tema
                icone = escrita.confirmada.icone
                erro = motivo.localizedDescription
            }
        }
    }

    /// Falhar aqui não é fatal: é só o ícone automático que fica sem fato para se
    /// basear. Vira aviso, não erro — e a escolha à mão continua disponível como
    /// saída.
    private func detectarSO() async {
        detectando = true
        avisoSO = nil
        erro = nil
        do {
            let atual = try await api.detectOS(name: machine.name)
            so = atual.os
            if (atual.os ?? "").isEmpty {
                avisoSO = "O host respondeu, mas não disse qual é o sistema. Escolha o ícone à mão."
            }
            onChanged()
        } catch {
            avisoSO = "Não deu para detectar o sistema agora: \(error.localizedDescription)"
        }
        detectando = false
    }
}

/// Par tema+ícone. Existe porque a rota é PUT, substituição: tratar os dois como
/// uma coisa só é o que impede mandar meia escolha e apagar a outra.
struct AparenciaDaMaquina: Equatable {
    var tema: String
    var icone: String
}

/// Leva a aparência ao hub com **um pedido em voo por vez**, coalescendo o que
/// chegou no meio do caminho.
///
/// Mora fora da View, e não em três `@State` soltos, porque é aqui que está a
/// regra que não é óbvia: dois PUT concorrentes podem chegar ao hub **fora de
/// ordem**, e aí o hub fica com o toque antigo enquanto a tela mostra o novo —
/// divergência que ninguém percebe até o próximo boot. Regra que não dá para
/// testar é regra que volta, e fora da View ela se testa com um envio falso.
@MainActor
final class EscritorDeAparencia: ObservableObject {
    enum Resultado {
        /// Chegou ao hub (possivelmente já levando escolhas mais novas).
        case gravou
        /// Ficou como próximo da fila; quem está enviando leva.
        case enfileirou
        case falhou(Error)
    }

    /// O que o hub confirmou. É para cá que um erro volta — e não para o valor de
    /// antes do último toque, que com toques em sequência já é palpite.
    @Published private(set) var confirmada: AparenciaDaMaquina
    @Published private(set) var enviando = false

    /// Escolha feita durante um envio. Guarda só a última: se ela tocou em três
    /// ícones, o hub não precisa ver os dois primeiros.
    private var pendente: AparenciaDaMaquina?
    private let enviar: (AparenciaDaMaquina) async throws -> Void

    init(confirmada: AparenciaDaMaquina,
         enviar: @escaping (AparenciaDaMaquina) async throws -> Void) {
        self.confirmada = confirmada
        self.enviar = enviar
    }

    func aplicar(_ alvo: AparenciaDaMaquina) async -> Resultado {
        guard !enviando else {
            pendente = alvo
            return .enfileirou
        }
        enviando = true
        defer { enviando = false }

        var atual = alvo
        while true {
            do {
                try await enviar(atual)
                confirmada = atual
            } catch {
                // Descarta a fila: insistir com o pendente depois de uma falha
                // só empilharia o mesmo erro, e a tela já vai desfazer.
                pendente = nil
                return .falhou(error)
            }
            guard let proximo = pendente else { return .gravou }
            pendente = nil
            atual = proximo
        }
    }
}
