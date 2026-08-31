import XCTest
@testable import CutuqueApp

/// A busca é o que separa "dá para olhar o arquivo no iPad" de "dá para ACHAR o
/// trecho no iPad". Estes testes cobrem as três coisas que quebrariam isso sem
/// aparecer na tela: o que casa, quantos são, e o passeio entre eles.
final class BuscaEmTextoTests: XCTestCase {
    private let linhas = [
        "func somar(a: Int, b: Int) -> Int {",
        "    return a + b",
        "}",
        "",
        "// somar de novo, e somar mais uma vez",
        "let total = somar(a: 1, b: 2)"
    ]

    func testAchaAsLinhasNaOrdemDoArquivo() {
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(linhas, termo: "somar"), [0, 4, 5])
    }

    /// Sem diferenciar maiúscula nem acento: digitar "funcao" e não achar
    /// `função` seria a pior forma de descobrir que a busca é literal.
    func testIgnoraCaixaEAcento() {
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(["a função aqui"], termo: "FUNCAO"), [0])
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(["Total"], termo: "total"), [0])
    }

    func testTermoVazioOuSoEspacoNaoAchaNada() {
        XCTAssertTrue(BuscaEmTexto.linhasComOcorrencia(linhas, termo: "").isEmpty)
        XCTAssertTrue(BuscaEmTexto.linhasComOcorrencia(linhas, termo: "   ").isEmpty)
        XCTAssertEqual(BuscaEmTexto.totalDeOcorrencias(linhas, termo: " "), 0)
    }

    /// Os dois números são diferentes de propósito: 3 linhas, 4 ocorrências.
    /// Um contador que dissesse "3" estaria mentindo sobre o que ela vai achar.
    func testContagemPorOcorrenciaNaoPorLinha() {
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(linhas, termo: "somar").count, 3)
        XCTAssertEqual(BuscaEmTexto.totalDeOcorrencias(linhas, termo: "somar"), 4)
    }

    /// Sem consumir o casamento, `range(of:)` acharia sempre o mesmo e o laço
    /// não terminaria.
    func testOcorrenciasColadasNaoTravamOLaco() {
        XCTAssertEqual(BuscaEmTexto.totalDeOcorrencias(["aaaa"], termo: "aa"), 2)
        XCTAssertEqual(BuscaEmTexto.totalDeOcorrencias(["", "x", ""], termo: "x"), 1)
    }

    func testNavegacaoDaAVoltaNasPontas() {
        XCTAssertEqual(BuscaEmTexto.proximo(2, total: 3), 0)
        XCTAssertEqual(BuscaEmTexto.proximo(0, total: 3), 1)
        XCTAssertEqual(BuscaEmTexto.anterior(0, total: 3), 2)
        XCTAssertEqual(BuscaEmTexto.anterior(2, total: 3), 1)
    }

    func testNavegacaoSemAchadosNaoEstoura() {
        XCTAssertEqual(BuscaEmTexto.proximo(0, total: 0), 0)
        XCTAssertEqual(BuscaEmTexto.anterior(0, total: 0), 0)
        XCTAssertEqual(BuscaEmTexto.indiceSeguro(5, total: 0), 0)
    }

    /// A lista de achados encolhe a cada tecla digitada; um índice velho maior
    /// que a lista nova estouraria o `achados[i]` na hora de rolar.
    func testIndiceVelhoEAparadoQuandoAListaEncolhe() {
        XCTAssertEqual(BuscaEmTexto.indiceSeguro(9, total: 3), 2)
        XCTAssertEqual(BuscaEmTexto.indiceSeguro(-4, total: 3), 0)
        XCTAssertEqual(BuscaEmTexto.indiceSeguro(1, total: 3), 1)
    }

    func testRotuloContaAPartirDeUm() {
        XCTAssertEqual(BuscaEmTexto.rotulo(indice: 0, achados: 12), "1 de 12")
        XCTAssertEqual(BuscaEmTexto.rotulo(indice: 2, achados: 12), "3 de 12")
        XCTAssertEqual(BuscaEmTexto.rotulo(indice: 99, achados: 12), "12 de 12")
        XCTAssertEqual(BuscaEmTexto.rotulo(indice: 0, achados: 0), "nenhuma")
    }

    /// O cabeçalho de `BuscaEmTexto` promete servir "o visualizador de arquivos
    /// E o diff". Por um tempo não serviu: `GitDiffView` tinha uma varredura
    /// própria com `localizedCaseInsensitiveContains`, sensível a acento —
    /// buscar "funcao" achava `função` numa tela e não achava na outra, no mesmo
    /// app e no mesmo dia. Este teste fixa a composição que a tela do diff usa.
    func testTextoDeLinhaDeDiffPassaPelaMesmaRegraDoVisualizador() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
        -func antiga() {}
        +func função() {}
         // fim
        """
        let linhas = DiffUnificado.parse(diff)[0].hunks[0].linhas
        let textos = linhas.map(\.texto)
        // Só a linha 1 casa: "func antiga() {}" não contém "funcao". O ponto é
        // que ela casa SEM o acento e SEM a caixa certa — a busca antiga do
        // diff, com `localizedCaseInsensitiveContains`, devolveria vazio.
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(textos, termo: "funcao"), [1])
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(textos, termo: "FUNÇÃO"), [1])
        XCTAssertEqual(BuscaEmTexto.linhasComOcorrencia(textos, termo: "fim"), [2])
        // E a navegação sobre os achados dá a volta, como na outra tela.
        XCTAssertEqual(BuscaEmTexto.proximo(1, total: 2), 0)
        XCTAssertEqual(BuscaEmTexto.anterior(0, total: 2), 1)
    }
}
