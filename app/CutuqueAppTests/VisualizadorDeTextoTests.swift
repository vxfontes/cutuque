import XCTest
@testable import CutuqueApp

/// O visualizador de texto da leva do preview (12/08/2026): roteamento de modo
/// (markdown renderizado x fonte colorida), indentação de JSON e a faixa da
/// cauda. Só a parte pura — sem montar `View` nenhuma, como o resto do projeto.
final class VisualizadorDeTextoTests: XCTestCase {

    // MARK: - Roteamento (.md / .json / .ts / .log)

    func testMarkdownAbreRenderizadoPorPadrao() {
        let tipo = TipoDeArquivo.de(nome: "README.md")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: false), .markdownRenderizado)
    }

    /// O botão "ver fonte" troca para o fonte colorido do PRÓPRIO markdown —
    /// `linguagemDoFonte` já cobre esse caso (é o mesmo campo usado pelo JSON).
    func testVerFonteDoMarkdownMostraFonteColoridoEmMarkdown() {
        let tipo = TipoDeArquivo.de(nome: "README.md")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: true), .fonte(.markdown))
    }

    func testJsonVaiParaFonteComALinguagemJson() {
        let tipo = TipoDeArquivo.de(nome: "pacote.json")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: false), .fonte(.json))
    }

    func testCodigoVaiParaFonteComALinguagemDoArquivo() {
        let tipo = TipoDeArquivo.de(nome: "App.ts")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: false), .fonte(.typescript))
    }

    /// `.log` não tem regra de realce: ainda é modo "fonte", só que sem
    /// linguagem — é o monoespaçado sem cor de sempre.
    func testLogVaiParaFonteSemLinguagem() {
        let tipo = TipoDeArquivo.de(nome: "saida.log")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: false), .fonte(nil))
    }

    /// `verFonte` não deveria nem ser olhado fora do markdown — um arquivo
    /// `.ts` não tem "renderizado" para alternar.
    func testVerFonteNaoMudaNadaForaDoMarkdown() {
        let tipo = TipoDeArquivo.de(nome: "App.ts")
        XCTAssertEqual(RoteadorDeTexto.modo(para: tipo, verFonte: true), .fonte(.typescript))
    }

    /// Cauda de `.md` nunca vira `markdownRenderizado`, nem com `verFonte`
    /// no padrão (`false`) — achado de revisão de 12/08/2026: o corte da
    /// cauda é cego (depois da primeira quebra de linha, sem noção de
    /// estrutura), pode cair no meio de uma cerca de código ou ênfase sem
    /// fechamento, e renderizar isso como markdown desenharia algo bem
    /// diferente do fim real do arquivo.
    func testCaudaDeMarkdownForcaModoFonteMesmoComVerFonteNoPadrao() {
        let tipo = TipoDeArquivo.de(nome: "CHANGELOG.md")
        XCTAssertEqual(
            RoteadorDeTexto.modo(para: tipo, verFonte: false, ehCauda: true),
            .fonte(.markdown)
        )
    }

    /// A mudança acima não pode vazar pro caso comum: markdown sem cauda
    /// continua renderizado por padrão.
    func testMarkdownSemCaudaContinuaRenderizadoPorPadrao() {
        let tipo = TipoDeArquivo.de(nome: "README.md")
        XCTAssertEqual(
            RoteadorDeTexto.modo(para: tipo, verFonte: false, ehCauda: false),
            .markdownRenderizado
        )
    }

    // MARK: - Indentação de JSON (função pura)

    /// Comparar só valor por chave (como esta asserção fazia antes) não pega
    /// embaralhamento de ordem nem reescrita de número — achado de revisão de
    /// 12/08/2026: a versão anterior de `indentar` passava por
    /// `JSONSerialization` pra reserializar, o que reordenava as chaves
    /// (ordem de iteração de `Dictionary` não é a do texto) e reescrevia
    /// número (`19.90` virava `19.899999999999999`). Por isso as chaves aqui
    /// estão de propósito fora de ordem alfabética (zebra, abacaxi, meio) e
    /// os números são exatamente os que a versão antiga corrompia — e a
    /// asserção agora é a STRING INTEIRA, não só os valores.
    func testJsonValidoSaiIndentadoEContinuaOMesmoDado() throws {
        let compacto = #"{"zebra":19.90,"abacaxi":0.0,"meio":-1.5e10,"lista":["b","a"]}"#
        let indentado = IndentadorDeJSON.indentar(compacto)

        XCTAssertNotEqual(indentado, compacto, "indentar tem que mudar alguma coisa, senão não fez nada")
        XCTAssertTrue(indentado.contains("\n"), "indentado tem quebra de linha")

        // Continua sendo o MESMO dado — só formatado para leitura: mesma
        // ordem de chave, mesma grafia de número, caractere por caractere.
        let esperado = """
        {
          "zebra": 19.90,
          "abacaxi": 0.0,
          "meio": -1.5e10,
          "lista": [
            "b",
            "a"
          ]
        }
        """
        XCTAssertEqual(indentado, esperado)
    }

    /// Objeto aninhado tem ordem própria também, não só o nível de cima —
    /// achado de revisão de 12/08/2026: um `package.json` real saía com a
    /// ordem de `"scripts"` embaralhada, não só a do topo.
    func testJsonValidoPreservaOrdemDeChaveEmObjetoAninhado() {
        let compacto = #"{"scripts":{"build":"tsc","start":"node ."},"nome":"cutuque"}"#
        let esperado = """
        {
          "scripts": {
            "build": "tsc",
            "start": "node ."
          },
          "nome": "cutuque"
        }
        """
        XCTAssertEqual(IndentadorDeJSON.indentar(compacto), esperado)
    }

    /// Objeto/array vazio não pode abrir uma quebra de linha vazia no meio —
    /// caso de borda do pretty-printer que caminha sobre o texto (em vez de
    /// reserializar), então tem teste próprio.
    func testJsonComObjetoEArrayVaziosSaiSemQuebraDeLinhaNoMeio() {
        let compacto = #"{"vazio":{},"lista":[]}"#
        let esperado = """
        {
          "vazio": {},
          "lista": []
        }
        """
        XCTAssertEqual(IndentadorDeJSON.indentar(compacto), esperado)
    }

    /// JSON quebrado (chave sem fechar) é o caso normal de um arquivo em
    /// edição — não é erro de tela, é texto cru como veio.
    func testJsonInvalidoVoltaExatamenteComoVeio() {
        let quebrado = #"{"nome": "sem fechar"#
        XCTAssertEqual(IndentadorDeJSON.indentar(quebrado), quebrado)
    }

    func testJsonVazioVoltaComoVeio() {
        XCTAssertEqual(IndentadorDeJSON.indentar(""), "")
    }

    /// A cauda de um `.json` gigante corta no meio da estrutura — vira JSON
    /// inválido quase sempre. Não pode travar: mesma regra do inválido comum.
    func testCaudaDeJsonCortadaNoMeioNaoQuebra() {
        let pedacoDeCauda = #"tro": "valor", "outro": [1, 2, 3]}"#
        XCTAssertEqual(IndentadorDeJSON.indentar(pedacoDeCauda), pedacoDeCauda)
    }

    // MARK: - Faixa de cauda

    func testFaixaDeCaudaApareceQuandoEhCauda() throws {
        let comCauda = FileContent(path: "/a.log", size: 5_000_000, binary: false,
                                    truncated: true, tail: true, content: "fim do arquivo")
        XCTAssertTrue(VisualizadorDeTexto.mostraFaixaDeCauda(comCauda))
    }

    /// Grande demais SEM cauda (hub antigo, antes do deploy desta leva) é outro
    /// motivo de não editar — não pode herdar o aviso de "isto é só o fim".
    func testFaixaDeCaudaNaoApareceQuandoSoTruncadoSemCauda() throws {
        let truncadoSemCauda = FileContent(path: "/a.log", size: 5_000_000, binary: false,
                                            truncated: true, tail: nil, content: "")
        XCTAssertFalse(VisualizadorDeTexto.mostraFaixaDeCauda(truncadoSemCauda))
    }

    func testFaixaDeCaudaNaoApareceEmArquivoNormal() throws {
        let normal = FileContent(path: "/a.md", size: 6, binary: false,
                                  truncated: false, tail: nil, content: "# oi\n")
        XCTAssertFalse(VisualizadorDeTexto.mostraFaixaDeCauda(normal))
    }

    // MARK: - Teto de realce: conteúdo inteiro, mesmo sem cor

    /// O visualizador não trunca nada por conta própria: quem decide "sem cor
    /// acima do teto" é o `RealceDeSintaxe` (Task R). A responsabilidade daqui
    /// é não perder um único caractere no caminho até ele.
    func testTextoAcimaDoTetoDeRealceChegaInteiroAoRealcador() {
        let grande = String(repeating: "linha de log de teste\n", count: 20_000)
        XCTAssertGreaterThan(grande.utf8.count, LimitesDeArquivo.tetoDeRealce)

        let tipo = TipoDeArquivo.de(nome: "gigante.log")
        guard case .fonte(let linguagem) = RoteadorDeTexto.modo(para: tipo, verFonte: false) else {
            return XCTFail("saida.log tem que ser modo fonte")
        }
        let exibido = VisualizadorDeTexto.textoParaExibir(grande, tipo: tipo)
        let saida = RealceDeSintaxe.aplicar(exibido, linguagem: linguagem)
        XCTAssertEqual(String(saida.characters), grande,
                        "acima do teto de realce o conteúdo tem que continuar inteiro, só sem cor")
    }

    /// Mesma garantia para código com linguagem conhecida — o teto vale por
    /// tamanho, não por tipo de arquivo.
    func testCodigoGrandeAcimaDoTetoDeRealceNaoPerdeCaractere() {
        let grande = String(repeating: "let x = 1 // comentário\n", count: 15_000)
        XCTAssertGreaterThan(grande.utf8.count, LimitesDeArquivo.tetoDeRealce)

        let tipo = TipoDeArquivo.de(nome: "Grande.swift")
        let exibido = VisualizadorDeTexto.textoParaExibir(grande, tipo: tipo)
        let saida = RealceDeSintaxe.aplicar(exibido, linguagem: tipo.linguagemDoFonte)
        XCTAssertEqual(String(saida.characters), grande)
    }
}
