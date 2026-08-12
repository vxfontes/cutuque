import XCTest
@testable import CutuqueApp

/// O modelo de abas do iPad. Três regras que a Vanessa travou (D1, D2):
/// aba de passagem é SUBSTITUÍDA ao tocar noutra coisa (modelo VS Code);
/// abrir um alvo que já está aberto FOCA a aba existente; nunca há duas abas
/// para o mesmo alvo.
final class OpenTabsTests: XCTestCase {

    private let a = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
    private let b = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%2")

    func testAbaDePassagemEhSubstituidaPelaProxima() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)          // passagem
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente)           // passagem
        XCTAssertEqual(t.abas.map(\.chave), [b], "a de passagem some no lugar da nova")
        XCTAssertEqual(t.selecionada, b)
    }

    func testAbaNormalNaoEhSubstituida() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente)
        XCTAssertEqual(t.abas.map(\.chave), [a, b])
    }

    /// Reabrir promove: é o equivalente do duplo clique do VS Code, e é o gesto
    /// que a Vanessa vai usar sem pensar quando quiser guardar a aba.
    func testReabrirUmaAbaDePassagemAPromoveENaoDuplica() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        XCTAssertEqual(t.abas.count, 1)
        XCTAssertEqual(t.abas[0].estilo, .normal)
        XCTAssertEqual(t.selecionada, a)
    }

    /// Abrir de novo NÃO troca o conteúdo vivo por um `.pendente` — senão focar
    /// uma aba restaurada e já reconciliada a jogaria de volta pro limbo.
    func testAbrirDeNovoPreservaOConteudoJaResolvido() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .board, estilo: .normal)
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        XCTAssertEqual(t.abas[0].conteudo, .board)
    }

    func testTituloEhAtualizadoQuandoAAbaJaExiste() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: a, titulo: "mike renomeada", conteudo: .pendente)
        XCTAssertEqual(t.abas[0].titulo, "mike renomeada")
    }

    func testSelecionarSobeAOrdemDeFoco() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente, estilo: .normal)
        t.selecionar(a)
        XCTAssertEqual(t.selecionada, a)
        XCTAssertGreaterThan(t.abas[0].ordemDeFoco, t.abas[1].ordemDeFoco)
    }

    func testSelecionarChaveInexistenteNaoMudaNada() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        let antes = t
        t.selecionar(b)
        XCTAssertEqual(t, antes)
    }

    /// Uma aba por destino singular: Board aberto duas vezes é uma aba.
    func testDestinosSingularesNaoDuplicam() {
        var t = OpenTabs()
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        XCTAssertEqual(t.abas.count, 1)
    }

    func testChaveDeLiveSeparaMaquinasComMesmoNomeDeGrupo() {
        // Por que isto tem teste: é a razão de `identidade-pane-ao-vivo` ser
        // pré-requisito. Dois grupos "defender", um em cada máquina, com o mesmo
        // socket — se a chave não levasse a máquina, seriam a MESMA aba.
        let noMacbook = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/tmp/defender\t%1")
        let noWindows = ChaveDeAba(tipo: .live, machine: "windows", alvo: "/tmp/defender\t%1")
        XCTAssertNotEqual(noMacbook, noWindows)
    }
}
