import XCTest
@testable import CutuqueApp

/// Filtro por máquina da tela inicial (`FiltroDeMaquinas`). O que realmente
/// pode sair errado aqui é a CONTAGEM do chip: a lista dedup a sessão que está
/// espelhada em "Ao vivo", então contar o registry cru daria um número que não
/// bate com o que a pessoa vê depois de tocar no chip.
final class FiltroDeMaquinasTests: XCTestCase {

    /// `Session` só tem init de decoder — monta uma a partir do JSON do hub.
    private func sessao(id: String = "s1",
                        machine: String = "macbook",
                        state: String = "running",
                        pane: String? = nil,
                        external: Bool = false) -> Session {
        // O TAB do alvo composto ("<socket>\t<pane>") tem de ir ESCAPADO no
        // JSON: um TAB cru dentro de string é JSON inválido, e o `try?` do
        // decoder de `Session` engoliria o erro devolvendo `pane` nulo — o
        // teste passaria a medir outra coisa.
        let paneJSON = pane.map { "\"\($0.replacingOccurrences(of: "\t", with: "\\t"))\"" } ?? "null"
        let json = """
        {"id":"\(id)","machine":"\(machine)","agent":"claude-code","title":"t",
         "state":"\(state)","created_at":"2026-09-20T10:00:00Z",
         "updated_at":"2026-09-20T10:00:00Z","pane":\(paneJSON),"external":\(external)}
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    private func viva(_ machine: String, _ target: String) -> LiveEntry {
        LiveEntry(machine: machine, session: DiscoveredSession(id: target, cwd: "/tmp", title: "t"))
    }

    // MARK: Filtrar

    func testTodasNaoFiltraNada() {
        let lista = [sessao(id: "a", machine: "macmini"), sessao(id: "b", machine: "windows")]
        XCTAssertEqual(FiltroDeMaquinas.sessoes(lista, maquina: FiltroDeMaquinas.todas).map(\.id), ["a", "b"])
        XCTAssertEqual(FiltroDeMaquinas.todas, "")
    }

    func testFiltroDeixaSoAMaquinaEscolhida() {
        let lista = [sessao(id: "a", machine: "macmini"),
                     sessao(id: "b", machine: "windows"),
                     sessao(id: "c", machine: "macmini")]
        XCTAssertEqual(FiltroDeMaquinas.sessoes(lista, maquina: "macmini").map(\.id), ["a", "c"])
        let vivas = [viva("macmini", "main\t%1"), viva("windows", "main\t%2")]
        XCTAssertEqual(FiltroDeMaquinas.vivas(vivas, maquina: "windows").map(\.machine), ["windows"])
    }

    // MARK: Máquinas oferecidas

    func testMaquinasMantemAOrdemDoHubEAcrescentaAsDasSessoes() {
        let maquinas = FiltroDeMaquinas.maquinas(
            conhecidas: ["macmini", "macbook"],
            sessoes: [sessao(machine: "windows"), sessao(machine: "macbook")],
            vivas: [viva("macmini", "main\t%1")])
        // Ordem do hub primeiro, a de fora (só nas sessões) depois.
        XCTAssertEqual(maquinas, ["macmini", "macbook", "windows"])
    }

    func testMaquinasNaoRepeteNemAceitaNomeVazio() {
        let maquinas = FiltroDeMaquinas.maquinas(
            conhecidas: ["macmini", "macmini", ""],
            sessoes: [sessao(machine: "macmini")],
            vivas: [])
        XCTAssertEqual(maquinas, ["macmini"])
    }

    // MARK: Contagem (o número do chip)

    func testContagemSomaSessoesPorMaquina() {
        let contagem = FiltroDeMaquinas.contagemPorMaquina(
            sessoes: [sessao(id: "a", machine: "macmini"),
                      sessao(id: "b", machine: "macmini"),
                      sessao(id: "c", machine: "windows")],
            vivas: [])
        XCTAssertEqual(contagem["macmini"], 2)
        XCTAssertEqual(contagem["windows"], 1)
        XCTAssertEqual(FiltroDeMaquinas.total(contagem), 3)
    }

    func testSessaoEspelhadaEmAoVivoContaUmaVezSo() {
        // A sessão roda num pane que está vivo e NÃO é needs_you: a lista a
        // mostra como linha de "Ao vivo" e some da seção "Sessões".
        let contagem = FiltroDeMaquinas.contagemPorMaquina(
            sessoes: [sessao(id: "a", machine: "macmini", pane: "main\t%1")],
            vivas: [viva("macmini", "main\t%1")])
        XCTAssertEqual(contagem["macmini"], 1)
    }

    func testPaneVivoDeNeedsYouContaPelaSessaoENaoPelaLinhaAoVivo() {
        // needs_you com pane vivo aparece SÓ em "Precisa de você".
        let contagem = FiltroDeMaquinas.contagemPorMaquina(
            sessoes: [sessao(id: "a", machine: "macmini", state: "needs_you", pane: "main\t%1")],
            vivas: [viva("macmini", "main\t%1")])
        XCTAssertEqual(contagem["macmini"], 1)
    }

    func testPaneVivoSemSessaoNoRegistryContaNaMaquinaDele() {
        let contagem = FiltroDeMaquinas.contagemPorMaquina(sessoes: [], vivas: [viva("windows", "main\t%9")])
        XCTAssertEqual(contagem["windows"], 1)
        XCTAssertEqual(FiltroDeMaquinas.total(contagem), 1)
    }

    func testSubagenteSemPaneContaNormalmente() {
        let contagem = FiltroDeMaquinas.contagemPorMaquina(
            sessoes: [sessao(id: "sub", machine: "macbook", external: true)], vivas: [])
        XCTAssertEqual(contagem["macbook"], 1)
    }

    func testMesmoPaneEmMaquinasDiferentesNaoSeConfunde() {
        // Dois Macs de mesmo uid produzem socket e pane idênticos — a contagem
        // não pode misturar as duas máquinas por causa disso.
        let contagem = FiltroDeMaquinas.contagemPorMaquina(
            sessoes: [], vivas: [viva("macmini", "main\t%1"), viva("macbook", "main\t%1")])
        XCTAssertEqual(contagem["macmini"], 1)
        XCTAssertEqual(contagem["macbook"], 1)
    }

    // MARK: Escolha inválida

    func testMaquinaQueSaiuDoHubVoltaParaTodas() {
        XCTAssertEqual(FiltroDeMaquinas.escolhaValida("windows", entre: ["macmini", "macbook"]),
                       FiltroDeMaquinas.todas)
    }

    func testMaquinaPresenteContinuaEscolhida() {
        XCTAssertEqual(FiltroDeMaquinas.escolhaValida("macmini", entre: ["macmini", "macbook"]), "macmini")
    }

    func testListaVaziaNaoApagaAEscolha() {
        // Estado normal enquanto o primeiro poll não voltou — zerar aqui
        // apagaria a escolha de quem só abriu o app.
        XCTAssertEqual(FiltroDeMaquinas.escolhaValida("macmini", entre: []), "macmini")
    }
}
