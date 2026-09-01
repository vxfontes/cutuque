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

/// Os links que a folha oferece para copiar sozinhos. Também é lógica pura, e
/// pelo mesmo motivo: meia URL colada não abre, e ela só descobriria no WhatsApp.
final class LinksNoTextoTests: XCTestCase {

    // MARK: o que conta como link

    func testAchaLinkComEsquema() {
        XCTAssertEqual(LinksNoTexto.encontrar("veja https://exemplo.com/a/b aqui"),
                       ["https://exemplo.com/a/b"])
    }

    func testAchaEnderecoSemEsquema() {
        XCTAssertEqual(LinksNoTexto.encontrar("abre www.google.com"), ["www.google.com"])
    }

    func testEmailVemComoEstaNaTela() {
        // E não `mailto:vanessa@example.com`, que é o que a `url` do match daria:
        // o que ela cola no WhatsApp é o que ela está lendo.
        XCTAssertEqual(LinksNoTexto.encontrar("manda pra vanessa@example.com"),
                       ["vanessa@example.com"])
    }

    func testNomeDeArquivoDeTerminalNaoViraLink() {
        // A lista fica em cima do texto: um `main.py` ali seria ruído em toda
        // tela de agente. Medido antes de escrever — o detector não cai nesses.
        let tela = "roda ./script.sh\nabre main.py e index.ts\nver package.json e README.md"
        XCTAssertEqual(LinksNoTexto.encontrar(tela), [])
    }

    func testCaminhoComBarraNaoViraLink() {
        XCTAssertEqual(LinksNoTexto.encontrar("leia docs/specs/2026-08-12-design.md"), [])
    }

    func testTextoSemLinkDaListaVazia() {
        XCTAssertEqual(LinksNoTexto.encontrar("nenhum link por aqui"), [])
    }

    func testRepetidoApareceUmaVezSoNaOrdemDaTela() {
        let tela = "b https://b.com\na https://a.com\nde novo https://b.com"
        XCTAssertEqual(LinksNoTexto.encontrar(tela), ["https://b.com", "https://a.com"])
    }

    // MARK: a URL que a grade partiu

    func testRemontaURLPartidaPelaLarguraDaGrade() {
        // "veja https://exemplo.com" tem exatamente a maior largura do bloco: numa
        // grade de terminal isso é transbordo, e o resto está na linha seguinte.
        let tela = "veja https://exemplo.com\n/a/b/c ok\nfim"
        XCTAssertEqual(LinksNoTexto.encontrar(tela), ["https://exemplo.com/a/b/c"])
    }

    func testRemontaURLPartidaEmTresLinhas() {
        let tela = "ver https://ex.com/a\naaaaaaaaaaaaaaaaaaaa\nbbb"
        XCTAssertEqual(LinksNoTexto.desdobrado(tela),
                       "ver https://ex.com/aaaaaaaaaaaaaaaaaaaaabbb")
    }

    func testParagrafoComumNaoGruda() {
        // Linha cheia que acaba em palavra normal é prosa, não URL partida. É o
        // risco simétrico da emenda, e é o que a torna tímida.
        let tela = "essa linha enche a grade\ne continua aqui"
        XCTAssertEqual(LinksNoTexto.desdobrado(tela), tela)
    }

    func testEmendaParaQuandoAURLAcaba() {
        // A segunda linha também é cheia, mas termina em palavra comum: a terceira
        // não pode ser grudada. Sem isso, uma URL no topo colaria a tela inteira.
        let tela = "veja https://exemplo.com\n/a e agora texto comum!!\nnao gruda"
        XCTAssertEqual(LinksNoTexto.desdobrado(tela),
                       "veja https://exemplo.com/a e agora texto comum!!\nnao gruda")
    }

    func testTextoVazioNaoQuebra() {
        XCTAssertEqual(LinksNoTexto.encontrar(""), [])
        XCTAssertEqual(LinksNoTexto.desdobrado(""), "")
    }
}
