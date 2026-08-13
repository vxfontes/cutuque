import XCTest
import SwiftUI
@testable import CutuqueApp

/// O tokenizador de realce (12/08/2026 — Task R da leva do preview de
/// arquivos). A asserção mais importante do arquivo inteiro é a de
/// **identidade**: não existe cor que valha perder um caractere.
///
/// Os testes tratam `RealceDeSintaxe.aplicar` como caixa-preta — não têm acesso
/// à tabela de linguagens nem ao tokenizador interno (são `private`), só ao
/// contrato público: `AttributedString` de entrada. Onde é preciso confirmar
/// QUAL trecho ficou de qual cor, o teste itera `attr.runs` e lê o
/// `foregroundColor`/`inlinePresentationIntent` de cada um.
final class RealceDeSintaxeTests: XCTestCase {

    /// Cada run do resultado como (texto do run, cor, intenção inline) — o
    /// jeito de inspecionar SEM conhecer a implementação por dentro.
    private struct Trecho { let texto: String; let cor: Color?; let intent: InlinePresentationIntent? }

    private func trechos(_ attr: AttributedString) -> [Trecho] {
        attr.runs.map { run in
            Trecho(
                texto: String(attr[run.range].characters),
                cor: run.foregroundColor,
                intent: run.inlinePresentationIntent
            )
        }
    }

    private func texto(_ attr: AttributedString) -> String { String(attr.characters) }

    // MARK: - A regra que vale mais que a cor

    /// Uma linguagem por vez, com uma amostra que usa comentário, string,
    /// número, palavra-chave e tipo — a concatenação das partes tem de bater
    /// com a entrada, sempre, para TODAS as linguagens da tabela.
    func testIdentidadeDoTextoPreservadaEmTodasAsLinguagens() {
        let amostras: [Linguagem: String] = [
            .swift: "// comentário\nfunc soma(a: Int, b: Int) -> Int {\n    return a + 1_0 // 10\n}\nlet s = \"oi \\\"aqui\\\"\"\n",
            .go: "// comentário\nfunc Soma(a, b int) int {\n\treturn a + 10\n}\nvar s = \"oi\"\n",
            .typescript: "// comentário\nfunction soma(a: number, b: number): number {\n  return a + 10\n}\nconst s = `oi ${a}`\n",
            .javascript: "// comentário\nfunction soma(a, b) {\n  return a + 10\n}\nconst s = 'oi'\n",
            .python: "# comentário\ndef soma(a, b):\n    return a + 10\ns = \"oi\"\n",
            .ruby: "# comentário\ndef soma(a, b)\n  a + 10\nend\ns = \"oi\"\n",
            .rust: "// comentário\nfn soma(a: i32, b: i32) -> i32 {\n    a + 10\n}\nlet s = \"oi\";\n",
            .java: "// comentário\nclass Soma {\n  int soma(int a, int b) { return a + 10; }\n}\n",
            .kotlin: "// comentário\nfun soma(a: Int, b: Int): Int {\n  return a + 10\n}\n",
            .c: "/* comentário */\nint soma(int a, int b) {\n  return a + 10;\n}\n",
            .cpp: "// comentário\nclass Soma {\npublic:\n  int soma(int a, int b) { return a + 10; }\n};\n",
            .shell: "# comentário\nfunction soma() {\n  echo $((1 + 10))\n}\n",
            .yaml: "# comentário\nnome: Cutuque\nativo: true\nversao: 1.0\n",
            .toml: "# comentário\nnome = \"Cutuque\"\nativo = true\n",
            .sql: "-- comentário\nSELECT nome FROM usuarios WHERE id = 10;\n",
            .html: "<!-- comentário -->\n<div class=\"a\">Olá 10</div>\n",
            .css: "/* comentário */\n.a { color: red; margin: 10px; }\n",
            .json: "// comentário\n{\"nome\": \"Cutuque\", \"versao\": 10}\n",
            .markdown: "# Título\n\nTexto com **negrito**, _itálico_ e `código`.\n\n```swift\nlet x = 1\n```\n\n- item\n> citação\n[link](http://x)\n",
        ]
        for linguagem in Linguagem.allCases {
            guard let amostra = amostras[linguagem] else {
                XCTFail("faltou amostra pra \(linguagem) — toda linguagem da tabela precisa de um caso aqui")
                continue
            }
            let saida = RealceDeSintaxe.aplicar(amostra, linguagem: linguagem)
            XCTAssertEqual(texto(saida), amostra, "identidade quebrou para \(linguagem)")
        }
    }

    func testEntradaPatologicaNaoQuebraIdentidade() {
        let patologicas = [
            "",
            "\"",
            "\"\"\"\"\"\"\"\"\"\"",
            "/* /* /* nunca fecha",
            "** __ * _ ` [ ] ( ) sem par nenhum",
            "```\n```\n```\n",
            String(repeating: "*", count: 5000),
            String(repeating: "\\", count: 2000) + "\"",
            "\n\n\n\n\n\n\n\n\n\n",
            "функция() { // não-ASCII no meio \n 你好 \"世界\" \n}",
        ]
        for entrada in patologicas {
            let saidaSwift = RealceDeSintaxe.aplicar(entrada, linguagem: .swift)
            XCTAssertEqual(texto(saidaSwift), entrada, "swift perdeu caractere em: \(entrada.prefix(30))")
            let saidaMd = RealceDeSintaxe.aplicar(entrada, linguagem: .markdown)
            XCTAssertEqual(texto(saidaMd), entrada, "markdown perdeu caractere em: \(entrada.prefix(30))")
        }
    }

    // MARK: - Comentário no fim do arquivo, sem quebra de linha

    func testComentarioDeLinhaNoFimDoArquivoSemQuebra() {
        let fonte = "let x = 1 // fim sem quebra"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).contains { $0.texto == "// fim sem quebra" && $0.cor == .secondary })
    }

    func testComentarioDeBlocoNuncaFechadoVaiAteOFim() {
        let fonte = "let x = 1\n/* nunca fecha, mas não pode travar nem sumir"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).contains { $0.texto.hasPrefix("/* nunca fecha") && $0.cor == .secondary })
    }

    // MARK: - String não fechada até o fim

    func testStringNaoFechadaVaiAteOFim() {
        let fonte = "let s = \"abc def"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).contains { $0.texto == "\"abc def" && $0.cor == .orange })
    }

    // MARK: - `//` dentro de string não vira comentário

    func testBarraDuplaDentroDeStringNaoViraComentario() {
        let fonte = "let url = \"http://exemplo.com\"\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        let ts = trechos(saida)
        // A string inteira (com o "//" dentro) é UM run só, colorido como string.
        XCTAssertTrue(ts.contains { $0.texto == "\"http://exemplo.com\"" && $0.cor == .orange })
        // E não existe um run separado tratando aquele "//" como comentário.
        XCTAssertFalse(ts.contains { $0.texto == "//" && $0.cor == .secondary })
    }

    func testMarcadorDeComentarioDentroDeStringDeLinguagemComHashTambemNaoConta() {
        let fonte = "nome = \"a # b\"\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .toml)
        XCTAssertEqual(texto(saida), fonte)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "\"a # b\"" && $0.cor == .orange })
        XCTAssertFalse(ts.contains { $0.cor == .secondary })
    }

    // MARK: - Número colado em identificador

    func testNumeroColadoEmIdentificadorFicaUmTokenSo() {
        let fonte = "let x1 = 10\nlet abc123def = 2\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        let ts = trechos(saida)
        // Trechos SEM cor viram um único run junto com o texto vizinho (é a
        // otimização de buffer — dois identificadores comuns lado a lado não
        // precisam de dois runs), então a asserção certa não é "x1" ser um run
        // isolado, e sim que "1" e "123" NUNCA aparecem como número (roxo)
        // separados do "x"/"abc" que os precede.
        XCTAssertFalse(ts.contains { $0.texto == "1" && $0.cor == .purple })
        XCTAssertFalse(ts.contains { $0.texto == "123" && $0.cor == .purple })
        XCTAssertTrue(ts.contains { $0.texto.contains("x1") })
        XCTAssertTrue(ts.contains { $0.texto.contains("abc123def") })
        // "10" sozinho (sem colar em letra) continua virando número de verdade.
        XCTAssertTrue(ts.contains { $0.texto == "10" && $0.cor == .purple })
    }

    func testIdentificadorComecandoComMaiusculaViraTipo() {
        let saida = RealceDeSintaxe.aplicar("let s: String = Self.padrao\n", linguagem: .swift)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "String" && $0.cor == .teal })
        XCTAssertTrue(ts.contains { $0.texto == "Self" && $0.cor == .teal })
    }

    func testPalavraChaveEhReconhecida() {
        let saida = RealceDeSintaxe.aplicar("if true { return }\n", linguagem: .swift)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "if" && $0.cor == .pink })
        XCTAssertTrue(ts.contains { $0.texto == "return" && $0.cor == .pink })
    }

    func testSqlIgnoraCaixaNaPalavraChave() {
        let maiuscula = trechos(RealceDeSintaxe.aplicar("SELECT * FROM t\n", linguagem: .sql))
        let minuscula = trechos(RealceDeSintaxe.aplicar("select * from t\n", linguagem: .sql))
        XCTAssertTrue(maiuscula.contains { $0.texto == "SELECT" && $0.cor == .pink })
        XCTAssertTrue(minuscula.contains { $0.texto == "select" && $0.cor == .pink })
    }

    func testSwiftNaoIgnoraCaixaNaPalavraChave() {
        // "IF" maiúsculo não é a palavra-chave `if` do Swift — é (na pior das
        // hipóteses) um identificador que começa com maiúscula, então vira
        // "tipo", não "palavra-chave". Ignorar caixa aqui seria BUG, não acerto.
        let saida = RealceDeSintaxe.aplicar("let IF = 1\n", linguagem: .swift)
        let ts = trechos(saida)
        XCTAssertFalse(ts.contains { $0.texto == "IF" && $0.cor == .pink })
    }

    // MARK: - Arquivo vazio

    func testArquivoVazioNaoQuebraEmNenhumaLinguagem() {
        for linguagem in Linguagem.allCases {
            let saida = RealceDeSintaxe.aplicar("", linguagem: linguagem)
            XCTAssertEqual(texto(saida), "", "\(linguagem)")
        }
        XCTAssertEqual(texto(RealceDeSintaxe.aplicar("", linguagem: nil)), "")
    }

    // MARK: - Acima do teto sai sem cor, sem varrer

    func testTextoAcimaDoTetoSaiSemCorMasComOConteudoInteiro() {
        // `func` é palavra-chave e SERIA colorida se estivesse abaixo do teto
        // — o teste prova que, acima dele, nem essa checagem roda.
        let fonte = "func destacavel() {}\n" + String(repeating: "a", count: LimitesDeArquivo.tetoDeRealce + 1)
        XCTAssertGreaterThan(fonte.utf8.count, LimitesDeArquivo.tetoDeRealce)
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).allSatisfy { $0.cor == nil })
    }

    func testTextoNoLimiteDoTetoAindaGanhaCor() {
        // Um arquivo JUSTO no teto (não acima) ainda passa pelo tokenizador —
        // é a borda oposta do teste anterior.
        let recheio = String(repeating: "a", count: LimitesDeArquivo.tetoDeRealce - 20)
        let fonte = "func f() {}\n" + recheio
        XCTAssertLessThanOrEqual(fonte.utf8.count, LimitesDeArquivo.tetoDeRealce)
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).contains { $0.texto == "func" && $0.cor == .pink })
    }

    func testTextoRealcadoAcimaDoTetoEhRapido() {
        // Não é benchmark de precisão — é uma rede de segurança contra reativar
        // sem querer um laço O(n²) escondido em algum canto. Limite folgado de
        // propósito (a máquina de CI pode ser mais lenta que a de dev).
        var fonte = ""
        // 3000 linhas fica perto do teto (200 KiB) sem estourar — a asserção
        // logo abaixo é a rede de segurança: se o template da linha mudar de
        // tamanho, ela avisa em vez de silenciosamente testar um arquivo menor
        // (e portanto mais rápido) do que o pretendido.
        for i in 0..<3000 {
            fonte += "func soma\(i)(a: Int, b: Int) -> Int { return a + b } // linha \(i)\n"
        }
        XCTAssertLessThanOrEqual(fonte.utf8.count, LimitesDeArquivo.tetoDeRealce, "amostra ficou maior que o teto sem querer")
        let inicio = Date()
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertLessThan(Date().timeIntervalSince(inicio), 3.0)
        XCTAssertEqual(texto(saida), fonte)
    }

    // MARK: - Sem linguagem reconhecida

    func testSemLinguagemDevolveSemCor() {
        let fonte = "qualquer texto aqui\ncom \"aspas\" e // barras\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: nil)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertTrue(trechos(saida).allSatisfy { $0.cor == nil })
    }

    // MARK: - Markdown: cerca de código não colore o miolo como prosa

    func testCercaDeCodigoSemLinguagemNaoColoreMioloComoProsa() {
        let fonte = "Antes.\n\n```\n**isto não é negrito aqui dentro**\n```\n\nDepois **isto sim é negrito**.\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .markdown)
        XCTAssertEqual(texto(saida), fonte)
        let ts = trechos(saida)
        // Dentro da cerca: nenhum run cobrindo o `**...**` interno pode ter
        // vindo com ênfase forte — o `**` ali é texto, não marcação.
        XCTAssertFalse(ts.contains { $0.texto.contains("isto não é negrito") && $0.intent == .stronglyEmphasized })
        XCTAssertTrue(ts.contains { $0.texto.contains("isto não é negrito") })
        // Fora da cerca, o `**isto sim...**` continua virando negrito de verdade.
        XCTAssertTrue(ts.contains { $0.texto == "**isto sim é negrito**" && $0.intent == .stronglyEmphasized })
    }

    func testCercaDeCodigoComLinguagemReconhecidaRecoloreOMiolo() {
        let fonte = "```swift\nlet x = 1 // comentário\n```\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .markdown)
        XCTAssertEqual(texto(saida), fonte)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "let" && $0.cor == .pink })
        XCTAssertTrue(ts.contains { $0.texto == "// comentário" && $0.cor == .secondary })
    }

    func testCercaDeCodigoNuncaFechadaVaiAteOFimDoArquivo() {
        let fonte = "texto antes\n```\nconteudo que nunca fecha a cerca"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .markdown)
        XCTAssertEqual(texto(saida), fonte)
    }

    // MARK: - Markdown: título, lista, citação, link

    func testTituloFicaComEnfaseForte() {
        let saida = RealceDeSintaxe.aplicar("# Título grande\ntexto\n", linguagem: .markdown)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "# Título grande" && $0.intent == .stronglyEmphasized })
    }

    func testItemDeListaTemMarcadorEmCorSecundaria() {
        let saida = RealceDeSintaxe.aplicar("- primeiro\n1. segundo\n", linguagem: .markdown)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "- " && $0.cor == .secondary })
        XCTAssertTrue(ts.contains { $0.texto == "1. " && $0.cor == .secondary })
    }

    func testCitacaoTemMarcadorEmCorSecundaria() {
        let saida = RealceDeSintaxe.aplicar("> uma citação\n", linguagem: .markdown)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == ">" && $0.cor == .secondary })
    }

    func testLinkFicaDestacado() {
        let saida = RealceDeSintaxe.aplicar("veja [o site](http://exemplo.com) aqui\n", linguagem: .markdown)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "[o site](http://exemplo.com)" && $0.cor == .blue })
    }

    func testCodigoInlineGanhaIntentDeCodigo() {
        let saida = RealceDeSintaxe.aplicar("use `RealceDeSintaxe` aqui\n", linguagem: .markdown)
        let ts = trechos(saida)
        XCTAssertTrue(ts.contains { $0.texto == "`RealceDeSintaxe`" && $0.intent == .code })
    }

    func testNegritoENaoFechadoViraTextoNormal() {
        let fonte = "isto tem ** solto sem fechar\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .markdown)
        XCTAssertEqual(texto(saida), fonte)
        XCTAssertFalse(trechos(saida).contains { $0.intent == .stronglyEmphasized })
    }
}
