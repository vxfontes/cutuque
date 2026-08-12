import XCTest
@testable import CutuqueApp

/// As regras puras de "o que exatamente vai pra área de transferência". Ficam
/// fora das Views (padrão da casa) porque é aqui que mora o que faz o texto ser
/// COLÁVEL — e um erro aqui a usuária só descobre no WhatsApp.
final class CopiarTextoTests: XCTestCase {

    // MARK: aparado

    func testAparaEspacoADireitaDeCadaLinha() {
        // A tela de um terminal é uma matriz 80x24 preenchida de espaço. Sem
        // aparar, cada linha colada leva uma cauda de espaços invisíveis.
        XCTAssertEqual(TextoParaCopiar.aparado("olá   \nmundo\t\n"), "olá\nmundo")
    }

    func testAparaLinhasVaziasDoFim() {
        XCTAssertEqual(TextoParaCopiar.aparado("conteúdo\n\n   \n\n"), "conteúdo")
    }

    func testPreservaLinhaVaziaNoMeio() {
        // Parágrafo é informação: aparar o meio destruiria a saída de um comando
        // que separa blocos por linha em branco.
        XCTAssertEqual(TextoParaCopiar.aparado("a\n\nb"), "a\n\nb")
    }

    func testTextoSoDeEspacoViraVazio() {
        // É o que permite desabilitar o botão em terminal ainda conectando, em
        // vez de copiar 24 linhas de nada.
        XCTAssertEqual(TextoParaCopiar.aparado("   \n\t\n  "), "")
        XCTAssertEqual(TextoParaCopiar.aparado(""), "")
    }

    func testNaoAparaEspacoAEsquerdaQueEIndentacao() {
        // Indentação (espaço à ESQUERDA) é conteúdo — código colado sem ela não
        // roda. Só a cauda some.
        XCTAssertEqual(TextoParaCopiar.aparado("def f():\n    return 1   \n"),
                       "def f():\n    return 1")
    }

    // MARK: doTerminal

    func testSelecaoDaUsuariaGanhaDaTela() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "só isto", tela: "a tela toda"),
                       "só isto")
    }

    func testSemSelecaoCaiNaTela() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: nil, tela: "a tela toda"),
                       "a tela toda")
    }

    func testSelecaoVaziaOuSoEspacoCaiNaTela() {
        // O SwiftTerm devolve string vazia quando a seleção existe mas não cobre
        // nada; cair na tela é melhor que copiar vazio.
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "", tela: "tela"), "tela")
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "   \n ", tela: "tela"), "tela")
    }

    func testOsDoisLadosSaemAparados() {
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: "sel   \n\n", tela: "x"), "sel")
        XCTAssertEqual(TextoParaCopiar.doTerminal(selecionado: nil, tela: "tela  \n\n\n"), "tela")
    }

    // MARK: deFerramenta

    func testComandoComResultado() {
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: "total 0"),
                       "$ ls -la\ntotal 0")
    }

    func testComandoAindaSemResultado() {
        // Tool call em voo: o resultado ainda não chegou. Copiar só o comando é o
        // certo — não uma linha vazia pendurada.
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: nil),
                       "$ ls -la")
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "ls -la", resultado: "   "),
                       "$ ls -la")
    }

    func testResultadoMultilinhaMantemAsLinhas() {
        XCTAssertEqual(TextoParaCopiar.deFerramenta(comando: "git status", resultado: "a\nb\n"),
                       "$ git status\na\nb")
    }
}
