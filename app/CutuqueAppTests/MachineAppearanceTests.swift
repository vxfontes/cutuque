import XCTest
@testable import CutuqueApp

/// Aparência da máquina (tema + ícone) e os modos da tela de cadastro.
///
/// Duas regras aqui não são óbvias e já custaram desenho:
/// 1. O ícone escolhido À MÃO vence o SO detectado, e um id desconhecido cai no
///    automático em vez de virar quadrado vazio — o hub valida só a FORMA do id,
///    então um app mais novo pode ter gravado um ícone que este não conhece.
/// 2. `retomar` e `editar` da mesma máquina são telas diferentes: se colidissem
///    no `id`, o `.sheet(item:)` reaproveitaria a tela errada.
final class MachineAppearanceTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    private func maquina(os: String?, icon: String?, theme: String? = nil) -> Machine {
        Machine(name: "vps", dest: "vx@192.0.2.50", port: 22, source: "app",
                hostFingerprint: "SHA256:abc", host: "192.0.2.50", identity: "vx",
                os: os, theme: theme, icon: icon)
    }

    // MARK: - Decode

    func testIconVemDoHubQuandoExiste() throws {
        let m: Machine = try decode("""
        {"name":"vps","dest":"vx@1.2.3.4","port":22,"source":"app","icon":"cloud","theme":"nord"}
        """)
        XCTAssertEqual(m.icon, "cloud")
        XCTAssertEqual(m.theme, "nord")
        XCTAssertEqual(m.displayIcon, "cloud")
    }

    /// Máquina cadastrada antes deste campo existir (e as do `hub.env`) vem sem
    /// `icon` — tem que continuar decodificando e cair no automático.
    func testMaquinaSemIconDecodificaECaiNoAutomatico() throws {
        let m: Machine = try decode("""
        {"name":"mac","dest":"vx@1.2.3.4","port":22,"source":"app","os":"Darwin 24.5.0"}
        """)
        XCTAssertNil(m.icon)
        XCTAssertEqual(m.displayIcon, "apple.logo")
    }

    // MARK: - Precedência do ícone

    func testEscolhaAMaoVenceOSODetectado() {
        // Host que o `uname` diz ser Linux, mas que a usuária marcou como nuvem.
        let m = maquina(os: "Ubuntu 22.04", icon: "cloud")
        XCTAssertEqual(m.displayIcon, "cloud")
        XCTAssertEqual(m.osIcon, "terminal", "o SO detectado segue intacto — ícone manual é escolha, SO é fato")
    }

    func testSemEscolhaUsaOSODetectado() {
        XCTAssertEqual(maquina(os: "Darwin 24.5.0", icon: nil).displayIcon, "apple.logo")
        XCTAssertEqual(maquina(os: "Windows 11", icon: nil).displayIcon, "pc")
    }

    /// `""` é o que o hub guarda quando a escolha é apagada pelo
    /// `PUT /appearance` — é "automático", não um ícone chamado vazio.
    func testIconVazioEhAutomatico() {
        XCTAssertEqual(maquina(os: "Debian 12", icon: "").displayIcon, "terminal")
        XCTAssertEqual(MachineIcon.symbol(escolhido: "", os: nil), "desktopcomputer")
    }

    /// Id que este app não conhece (gravado por uma versão mais nova) não pode
    /// virar `Image(systemName:)` inexistente — quadrado vazio na lista.
    func testIconDesconhecidoCaiNoAutomatico() {
        XCTAssertEqual(maquina(os: "Darwin 24.5.0", icon: "holograma").displayIcon, "apple.logo")
        XCTAssertEqual(maquina(os: nil, icon: "holograma").displayIcon, "desktopcomputer")
    }

    func testSemSONemEscolhaFicaGenerico() {
        XCTAssertEqual(maquina(os: nil, icon: nil).displayIcon, "desktopcomputer")
        XCTAssertEqual(maquina(os: "", icon: "").displayIcon, "desktopcomputer")
    }

    /// Todo caso da tabela tem símbolo e rótulo próprios — a grade de escolha
    /// desenha exatamente esta lista.
    func testTodoIconeDaTabelaTemSimboloERotuloUnicos() {
        let simbolos = MachineIcon.allCases.map(\.symbol)
        let rotulos = MachineIcon.allCases.map(\.label)
        XCTAssertEqual(Set(simbolos).count, simbolos.count, "dois ícones com o mesmo símbolo ficam indistinguíveis na grade")
        XCTAssertEqual(Set(rotulos).count, rotulos.count)
        XCTAssertTrue(simbolos.allSatisfy { !$0.isEmpty })
        // Ida e volta pelo id: é assim que a escolha viaja até o hub e volta.
        for caso in MachineIcon.allCases {
            XCTAssertEqual(MachineIcon(rawValue: caso.id), caso)
            XCTAssertEqual(MachineIcon.symbol(escolhido: caso.id, os: "Darwin"), caso.symbol)
        }
    }

    // MARK: - Modos da tela de cadastro

    /// O buraco que este teste fecha: `retomar` e `editar` com o MESMO `id`
    /// faziam o `.sheet(item:)` considerar as duas a mesma tela — abrir "editar"
    /// depois de "retomar" reapresentaria a de campos travados.
    func testRetomarEEditarNaoColidemNoID() {
        let m = maquina(os: nil, icon: nil)
        XCTAssertNotEqual(NewMachineView.Modo.retomar(m).id, NewMachineView.Modo.editar(m).id)
        XCTAssertNotEqual(NewMachineView.Modo.nova.id, NewMachineView.Modo.retomar(m).id)
    }

    func testModoCarregaAMaquinaSoQuandoElaExiste() {
        let m = maquina(os: nil, icon: nil)
        XCTAssertNil(NewMachineView.Modo.nova.machine)
        XCTAssertEqual(NewMachineView.Modo.retomar(m).machine, m)
        XCTAssertEqual(NewMachineView.Modo.editar(m).machine, m)
    }

    /// `editando` é o que abre os campos, esconde o tema e tira o botão de
    /// apagar — nenhum outro modo pode responder verdadeiro.
    func testSoOModoEditarEhEdicao() {
        let m = maquina(os: nil, icon: nil)
        XCTAssertTrue(NewMachineView.Modo.editar(m).editando)
        XCTAssertFalse(NewMachineView.Modo.retomar(m).editando)
        XCTAssertFalse(NewMachineView.Modo.nova.editando)
    }

    // MARK: - Porta

    /// O hub recusa porta acima do teto TCP — e faz certo —, mas recusa depois do
    /// toque. Validar aqui é o que transforma "70000" num ✓ apagado em vez de num
    /// erro vindo da rede. `0` não passa: o hub trata zero como "não informada" e
    /// rebaixaria para 22 calado, que não é o que quem digitou zero pediu.
    func testPortaValidaAceitaSoAFaixaTCP() {
        XCTAssertEqual(NewMachineView.portaValida("22"), 22)
        XCTAssertEqual(NewMachineView.portaValida("1"), 1)
        XCTAssertEqual(NewMachineView.portaValida("65535"), 65535)
        XCTAssertEqual(NewMachineView.portaValida(" 2222 "), 2222, "valor colado vem com espaço")

        for ruim in ["", "  ", "0", "-1", "65536", "70000", "999999", "22a", "2 2", "vinte", "22.5"] {
            XCTAssertNil(NewMachineView.portaValida(ruim), "porta \(ruim.debugDescription) não devia passar")
        }
    }

    // MARK: - Escrita de aparência (um pedido em voo por vez)

    private struct ErroDeTeste: Error {}

    /// Envio falso que **trava** no primeiro pedido: é o único jeito de ter toques
    /// novos com um pedido ainda em voo, que é a situação inteira que a fila existe
    /// para resolver.
    @MainActor
    private final class EnvioFalso {
        var recebidos: [AparenciaDaMaquina] = []
        var travarNoPrimeiro = true
        var erroNoPrimeiro: Error?

        private var travar: CheckedContinuation<Void, Never>?
        private var avisar: CheckedContinuation<Void, Never>?
        private var entrou = false

        func enviar(_ alvo: AparenciaDaMaquina) async throws {
            recebidos.append(alvo)
            guard recebidos.count == 1, travarNoPrimeiro else { return }
            entrou = true
            avisar?.resume()
            avisar = nil
            await withCheckedContinuation { travar = $0 }
            if let erroNoPrimeiro { throw erroNoPrimeiro }
        }

        /// Volta quando o primeiro pedido está dentro do envio, parado.
        func esperarPrimeiro() async {
            if entrou { return }
            await withCheckedContinuation { avisar = $0 }
        }

        func soltar() {
            travar?.resume()
            travar = nil
        }
    }

    /// Tocar em três ícones num hub lento disparava três PUTs concorrentes, que
    /// podem chegar **fora de ordem**: o hub ficaria com o toque antigo enquanto a
    /// tela mostra o novo, e ninguém percebe até o próximo boot.
    @MainActor
    func testUmPedidoEmVooEOUltimoToqueVence() async {
        let falso = EnvioFalso()
        let escritor = EscritorDeAparencia(confirmada: AparenciaDaMaquina(tema: "", icone: ""),
                                           enviar: { try await falso.enviar($0) })

        let primeiro = AparenciaDaMaquina(tema: "dracula", icone: "server")
        let corrida = Task { await escritor.aplicar(primeiro) }
        await falso.esperarPrimeiro()
        XCTAssertTrue(escritor.enviando)

        let meio = AparenciaDaMaquina(tema: "nord", icone: "cloud")
        let ultimo = AparenciaDaMaquina(tema: "", icone: "pc")
        guard case .enfileirou = await escritor.aplicar(meio),
              case .enfileirou = await escritor.aplicar(ultimo) else {
            return XCTFail("toque durante um envio tem de entrar na fila, não sair como segundo PUT")
        }
        XCTAssertEqual(falso.recebidos, [primeiro], "saiu um segundo PUT com o primeiro em voo")

        falso.soltar()
        guard case .gravou = await corrida.value else { return XCTFail("o primeiro envio devia terminar gravando") }
        XCTAssertEqual(falso.recebidos, [primeiro, ultimo], "o toque do meio não interessa ao hub")
        XCTAssertEqual(escritor.confirmada, ultimo)
        XCTAssertFalse(escritor.enviando)
    }

    /// Falhou: o confirmado continua sendo o que o hub aceitou (é para lá que a
    /// tela desfaz), e a fila é descartada — insistir empilharia o mesmo erro.
    @MainActor
    func testFalhaMantemOConfirmadoEDescartaAFila() async {
        let falso = EnvioFalso()
        falso.erroNoPrimeiro = ErroDeTeste()
        let inicial = AparenciaDaMaquina(tema: "nord", icone: "cloud")
        let escritor = EscritorDeAparencia(confirmada: inicial,
                                           enviar: { try await falso.enviar($0) })

        let corrida = Task { await escritor.aplicar(AparenciaDaMaquina(tema: "dracula", icone: "server")) }
        await falso.esperarPrimeiro()
        _ = await escritor.aplicar(AparenciaDaMaquina(tema: "", icone: "pc"))
        falso.soltar()

        guard case .falhou = await corrida.value else { return XCTFail("o erro do hub tem de chegar à tela") }
        XCTAssertEqual(escritor.confirmada, inicial, "o hub não aceitou nada, então nada foi confirmado")
        XCTAssertEqual(falso.recebidos.count, 1, "a fila devia ser descartada no erro")
        XCTAssertFalse(escritor.enviando)
    }

    /// Sem toque no meio, cada escolha vai ao hub — a fila não pode virar filtro.
    @MainActor
    func testEnviosEmSequenciaVaoTodosAoHub() async {
        let falso = EnvioFalso()
        falso.travarNoPrimeiro = false
        let escritor = EscritorDeAparencia(confirmada: AparenciaDaMaquina(tema: "", icone: ""),
                                           enviar: { try await falso.enviar($0) })

        let a = AparenciaDaMaquina(tema: "dracula", icone: "")
        let b = AparenciaDaMaquina(tema: "dracula", icone: "cloud")
        guard case .gravou = await escritor.aplicar(a), case .gravou = await escritor.aplicar(b) else {
            return XCTFail("envio em sequência devia gravar as duas vezes")
        }
        XCTAssertEqual(falso.recebidos, [a, b])
        XCTAssertEqual(escritor.confirmada, b)
    }

    // MARK: - Segmentos da chrome (13/08/2026 — abas de navegador e chrome única)

    /// Ids de `MachinePane`, não de `PaneMode`: as duas abas (sessão e máquina)
    /// usam a MESMA `ChromeDaAba`, e o registro em `NavigationState` é por
    /// CHAVE DE ABA — "terminal" numa não é "terminal" na outra. A ponte de
    /// cada painel converte com o SEU enum (aqui, `MachinePane(rawValue:)`).
    @MainActor
    func testChromeDaMaquinaUsaOsIdsDeMachinePane() {
        let nav = NavigationState()
        let chave = ChaveDeAba.maquina("macmini")
        nav.definirSegmentos(MachineDetailView.segmentosDeChrome(), de: chave)
        XCTAssertEqual(nav.segmentos(de: chave).map(\.id),
                       [MachinePane.terminal.rawValue, MachinePane.files.rawValue])
        XCTAssertEqual(nav.segmentos(de: chave).map(\.titulo), ["Terminal", "Arquivos"])
    }

    /// A lista é `MachinePane.allCases`, então crescer o enum (um terceiro
    /// painel, um dia) cresce a chrome sozinho — sem lembrar de tocar aqui
    /// também. Este teste falha primeiro se algum dia isso divergir.
    func testSegmentosSeguemTodosOsCasosDoMachinePane() {
        let s = MachineDetailView.segmentosDeChrome()
        XCTAssertEqual(s.count, MachinePane.allCases.count)
        for pane in MachinePane.allCases {
            XCTAssertTrue(s.contains { $0.id == pane.rawValue && $0.simbolo == pane.symbol })
        }
    }
}
