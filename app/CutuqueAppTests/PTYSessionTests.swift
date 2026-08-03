import XCTest
@testable import CutuqueApp

/// Lógica pura do terminal livre: a URL do WebSocket, o protocolo de texto e o
/// que cada estado significa para a usuária. Nada aqui abre socket — o proxy de
/// bytes em si é testado no hub, com um PTY de verdade.
final class PTYSessionTests: XCTestCase {

    // MARK: - URL do WebSocket

    /// O tamanho vai no handshake porque o app mede a tela ANTES de conectar:
    /// sem isso o shell abre 80x24 e desenha o prompt torto até o resize chegar.
    func testURLLevaTokenETamanhoNoHandshake() {
        let url = PTYSession.ptyURL(machine: "vps", cols: 120, rows: 45,
                                    base: URL(string: "http://100.100.125.103:8787")!, token: "segredo")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        XCTAssertEqual(comps.scheme, "ws")
        XCTAssertEqual(comps.path, "/machines/vps/pty")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["token"], "segredo")
        XCTAssertEqual(query["cols"], "120")
        XCTAssertEqual(query["rows"], "45")
    }

    /// Hub em https fala wss. Sem isto o WebSocket sairia em claro numa conexão
    /// que a usuária configurou como cifrada.
    func testHubEmHTTPSViraWSS() {
        let url = PTYSession.ptyURL(machine: "vps", cols: 80, rows: 24,
                                    base: URL(string: "https://hub.exemplo")!, token: "t")
        XCTAssertEqual(url.scheme, "wss")
    }

    /// Nome de máquina não é caminho: um nome com espaço ou barra tem que ser
    /// escapado, não montar rota nova.
    func testNomeDeMaquinaEhEscapadoNoCaminho() {
        let url = PTYSession.ptyURL(machine: "mac mini", cols: 80, rows: 24,
                                    base: URL(string: "http://h:8787")!, token: "t")
        XCTAssertTrue(url.absoluteString.contains("/machines/mac%20mini/pty"),
                      "URL = \(url.absoluteString)")
    }

    /// O hub lê `{"type":"resize","cols","rows"}` — o formato é contrato, não
    /// detalhe. Mudou aqui sem mudar lá e o terminal para de redimensionar em
    /// silêncio (nada quebra, só fica errado).
    func testMensagemDeResizeTemOFormatoQueOHubLe() {
        let json = PTYSession.resizeJSON(cols: 120, rows: 45)
        XCTAssertEqual(json, #"{"type":"resize","cols":120,"rows":45}"#)

        struct Ctl: Decodable { let type: String; let cols: Int; let rows: Int }
        let ctl = try? JSONDecoder().decode(Ctl.self, from: Data(json.utf8))
        XCTAssertEqual(ctl?.type, "resize")
        XCTAssertEqual(ctl?.cols, 120)
        XCTAssertEqual(ctl?.rows, 45)
    }

    // MARK: - Eventos do hub

    func testEventoDeSaidaTrazOCodigo() {
        XCTAssertEqual(PTYEvent(json: #"{"type":"exit","code":7}"#), .exit(7))
    }

    /// `code` omitido é o `omitempty` do Go quando a saída foi 0 — sair limpo
    /// não pode virar "não entendi o evento".
    func testSaidaLimpaVemSemCodigoEValeZero() {
        XCTAssertEqual(PTYEvent(json: #"{"type":"exit"}"#), .exit(0))
    }

    func testEventoDeErroTrazAMensagem() {
        XCTAssertEqual(PTYEvent(json: #"{"type":"error","message":"fork/exec: no pty"}"#),
                       .erro("fork/exec: no pty"))
    }

    /// Um hub mais novo mandando um evento que este app não conhece não pode
    /// derrubar o terminal — ignorar é o comportamento certo.
    func testEventoDesconhecidoOuLixoEhIgnorado() {
        XCTAssertNil(PTYEvent(json: #"{"type":"nada-disso"}"#))
        XCTAssertNil(PTYEvent(json: "isso não é json"))
        XCTAssertNil(PTYEvent(json: ""))
    }

    // MARK: - Estado

    /// Só um estado terminal autoriza abrir de novo. Sem isso, um `abre()` com
    /// o terminal vivo derrubaria o shell da usuária.
    func testSoEstadoTerminalPermiteAbrirDeNovo() {
        XCTAssertFalse(PTYSession.Estado.parado.acabou)
        XCTAssertFalse(PTYSession.Estado.conectando.acabou)
        XCTAssertFalse(PTYSession.Estado.ligado.acabou)
        XCTAssertTrue(PTYSession.Estado.encerrado(0).acabou)
        XCTAssertTrue(PTYSession.Estado.caiu("sem rota").acabou)
    }

    /// "Você digitou exit" e "a conexão caiu" precisam chegar diferentes: uma é
    /// normal, a outra é problema.
    func testCadaFimTemSeuRecado() {
        XCTAssertEqual(PTYSession.Estado.encerrado(0).recado, "Terminal encerrado.")
        XCTAssertEqual(PTYSession.Estado.encerrado(7).recado, "Terminal encerrado (código 7).")
        XCTAssertEqual(PTYSession.Estado.caiu("sem rota para o host").recado, "sem rota para o host")
    }

    /// Terminal rodando não tem recado — é o que mantém o aviso fora da tela
    /// enquanto está tudo bem.
    func testTerminalVivoNaoTemRecado() {
        XCTAssertNil(PTYSession.Estado.parado.recado)
        XCTAssertNil(PTYSession.Estado.conectando.recado)
        XCTAssertNil(PTYSession.Estado.ligado.recado)
    }

    // MARK: - Painel lembrado por host

    /// A chave é por host de propósito: a máquina onde se edita arquivo e a
    /// máquina onde se roda comando não são a mesma.
    func testCadaHostLembraOProprioPainel() {
        XCTAssertEqual(MachinePane.storageKey(machine: "vps"), "cutuque.machinePane.vps")
        XCTAssertNotEqual(MachinePane.storageKey(machine: "vps"),
                          MachinePane.storageKey(machine: "macmini"))
    }

    /// Valor gravado que não existe mais (versão velha do app, chave editada)
    /// cai no terminal em vez de deixar o painel indefinido.
    func testPainelGravadoInvalidoCaiNoTerminal() {
        XCTAssertEqual(MachinePane(rawValue: "terminal"), .terminal)
        XCTAssertEqual(MachinePane(rawValue: "files"), .files)
        XCTAssertNil(MachinePane(rawValue: "sei-la"))
    }
}
