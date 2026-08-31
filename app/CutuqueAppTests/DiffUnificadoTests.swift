import XCTest
@testable import CutuqueApp

/// O parser de diff é a base da tela nova de alterações: se ele errar a
/// numeração ou perder linha, a tela mente sobre o código dela. Por isso os
/// casos aqui são os do mundo real (`git diff` de verdade), não amostras
/// idealizadas.
final class DiffUnificadoTests: XCTestCase {

    // MARK: Cabeçalho de hunk

    func testCabecalhoComQuantidades() {
        let c = DiffUnificado.lerCabecalho("@@ -12,7 +14,9 @@ func exemplo() {")
        XCTAssertEqual(c.antigaInicio, 12)
        XCTAssertEqual(c.antigaQtd, 7)
        XCTAssertEqual(c.novaInicio, 14)
        XCTAssertEqual(c.novaQtd, 9)
        XCTAssertEqual(c.contexto, "func exemplo() {")
    }

    /// Quantidade ausente vale 1 — é o formato, não um atalho nosso.
    func testCabecalhoSemQuantidadeValeUm() {
        let c = DiffUnificado.lerCabecalho("@@ -1 +1 @@")
        XCTAssertEqual(c.antigaQtd, 1)
        XCTAssertEqual(c.novaQtd, 1)
        XCTAssertEqual(c.contexto, "")
    }

    func testCaminhoDeMarcador() {
        XCTAssertEqual(DiffUnificado.caminhoDeMarcador("+++ b/app/x.swift"), "app/x.swift")
        XCTAssertEqual(DiffUnificado.caminhoDeMarcador("--- a/app/x.swift"), "app/x.swift")
        XCTAssertNil(DiffUnificado.caminhoDeMarcador("+++ /dev/null"))
    }

    // MARK: Numeração

    /// O ponto do parser inteiro: saber em que linha do arquivo REAL cada
    /// mudança caiu. Contexto anda dos dois lados, adição só do novo, remoção
    /// só do antigo.
    func testNumeracaoDeLinhas() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -10,4 +10,5 @@ contexto
         um
        -dois
        +DOIS
        +dois e meio
         tres
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.count, 1)
        let linhas = arquivos[0].hunks[0].linhas
        XCTAssertEqual(linhas.map(\.tipo), [.contexto, .remocao, .adicao, .adicao, .contexto])
        XCTAssertEqual(linhas.map(\.antiga), [10, 11, nil, nil, 12])
        XCTAssertEqual(linhas.map(\.nova), [10, nil, 11, 12, 13])
        XCTAssertEqual(linhas.map(\.texto), ["um", "dois", "DOIS", "dois e meio", "tres"])
        XCTAssertEqual(arquivos[0].adicoes, 2)
        XCTAssertEqual(arquivos[0].remocoes, 1)
    }

    /// Um arquivo com duas mudanças distantes vira dois hunks, cada um com sua
    /// própria origem de numeração.
    func testDoisHunksNoMesmoArquivo() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
        -a
        +A
         b
        @@ -50,2 +50,2 @@
        -z
        +Z
         w
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos[0].hunks.count, 2)
        XCTAssertEqual(arquivos[0].hunks[0].linhas.first?.antiga, 1)
        XCTAssertEqual(arquivos[0].hunks[1].linhas.first?.antiga, 50)
        XCTAssertEqual(arquivos[0].adicoes, 2)
        XCTAssertEqual(arquivos[0].remocoes, 2)
    }

    // MARK: Fronteira entre arquivos

    /// O caso que quebra qualquer parser ingênuo: o `--- a/b.txt` do arquivo
    /// SEGUINTE começa com `-`, e um parser que decide o fim do hunk por
    /// "linha que não começa com +/-/espaço" o lê como remoção — e desalinha
    /// tudo dali para a frente. Quem decide o fim aqui é a conta do cabeçalho.
    func testMarcadorDoProximoArquivoNaoViraRemocao() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -a
        +A
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1,1 +1,1 @@
        -b
        +B
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.map(\.caminho), ["a.txt", "b.txt"])
        XCTAssertEqual(arquivos[0].hunks[0].linhas.count, 2)
        XCTAssertEqual(arquivos[1].hunks[0].linhas.map(\.texto), ["b", "B"])
        XCTAssertEqual(arquivos[0].adicoes, 1)
        XCTAssertEqual(arquivos[1].adicoes, 1)
    }

    /// Linha de conteúdo que POR SI SÓ parece um marcador (`--- coisa` dentro
    /// de um bloco de código markdown, por exemplo) continua sendo conteúdo
    /// enquanto a conta do hunk não fechou.
    func testLinhaDeConteudoQueParecMarcador() {
        let diff = """
        diff --git a/a.md b/a.md
        --- a/a.md
        +++ b/a.md
        @@ -1,3 +1,3 @@
         ---
        --- antigo
        +++ novo
        """
        let arquivos = DiffUnificado.parse(diff)
        let linhas = arquivos[0].hunks[0].linhas
        XCTAssertEqual(linhas.map(\.tipo), [.contexto, .remocao, .adicao])
        XCTAssertEqual(linhas.map(\.texto), ["---", "-- antigo", "++ novo"])
    }

    // MARK: Casos especiais de arquivo

    func testArquivoNovoUsaNomeDoLadoNovo() {
        let diff = """
        diff --git a/novo.swift b/novo.swift
        new file mode 100644
        index 000..111
        --- /dev/null
        +++ b/novo.swift
        @@ -0,0 +1,2 @@
        +import Foundation
        +// oi
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos[0].caminho, "novo.swift")
        XCTAssertEqual(arquivos[0].adicoes, 2)
        XCTAssertEqual(arquivos[0].remocoes, 0)
        XCTAssertEqual(arquivos[0].hunks[0].linhas.map(\.nova), [1, 2])
        XCTAssertEqual(arquivos[0].linguagem, .swift)
    }

    func testArquivoApagadoUsaNomeDoLadoAntigo() {
        let diff = """
        diff --git a/velho.txt b/velho.txt
        deleted file mode 100644
        --- a/velho.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -tchau
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos[0].caminho, "velho.txt")
        XCTAssertEqual(arquivos[0].remocoes, 1)
    }

    func testRenameGuardaOCaminhoAntigo() {
        let diff = """
        diff --git a/velho.txt b/novo.txt
        similarity index 90%
        rename from velho.txt
        rename to novo.txt
        --- a/velho.txt
        +++ b/novo.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos[0].caminho, "novo.txt")
        XCTAssertEqual(arquivos[0].caminhoAntigo, "velho.txt")
    }

    func testBinarioNaoTemLinhaMasApareceNaLista() {
        let diff = """
        diff --git a/img.png b/img.png
        index 111..222 100644
        Binary files a/img.png and b/img.png differ
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.count, 1)
        XCTAssertTrue(arquivos[0].binario)
        XCTAssertTrue(arquivos[0].hunks.isEmpty)
    }

    /// Mudança só de permissão não traz `---`/`+++`; o nome tem de vir do
    /// `diff --git`.
    func testMudancaDeModoSemMarcadores() {
        let diff = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.map(\.caminho), ["script.sh"])
        XCTAssertEqual(arquivos[0].adicoes, 0)
    }

    // MARK: Robustez

    /// `GitDiff.truncated`: o hub corta em MAX_DIFF_BYTES e o último hunk pode
    /// acabar no meio. Não é erro — é para mostrar o que chegou.
    func testDiffCortadoNoMeioNaoPerdeOQueVeio() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,9 +1,9 @@
         um
        -dois
        +DO
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.count, 1)
        XCTAssertEqual(arquivos[0].hunks[0].linhas.count, 3)
        XCTAssertEqual(arquivos[0].adicoes, 1)
    }

    /// Hub antigo manda `color.ui=always`. O app novo tem de continuar lendo.
    func testToleraANSIDeHubAntigo() {
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n"
            + "\u{1B}[36m@@ -1,1 +1,1 @@\u{1B}[m\n"
            + "\u{1B}[31m-a\u{1B}[m\n\u{1B}[32m+b\u{1B}[m"
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.count, 1)
        XCTAssertEqual(arquivos[0].hunks[0].linhas.map(\.texto), ["a", "b"])
        XCTAssertEqual(arquivos[0].adicoes, 1)
        XCTAssertEqual(arquivos[0].remocoes, 1)
    }

    func testTextoVazioEPreambuloNaoViramArquivo() {
        XCTAssertTrue(DiffUnificado.parse("").isEmpty)
        XCTAssertTrue(DiffUnificado.parse("lixo\nsem diff nenhum\n").isEmpty)
    }

    /// Linha de contexto VAZIA é conteúdo, não separador: descartá-la
    /// desalinharia a numeração de tudo abaixo dela.
    func testLinhaVaziaDeContextoContaNaNumeracao() {
        // Contagem do cabeçalho fecha exata (2 de cada lado): a linha vazia é
        // uma das duas. Se ela fosse descartada, `-x` viraria a linha 1.
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n \n-x\n+y\n"
        let arquivos = DiffUnificado.parse(diff)
        let linhas = arquivos[0].hunks[0].linhas
        XCTAssertEqual(linhas.map(\.tipo), [.contexto, .remocao, .adicao])
        XCTAssertEqual(linhas[1].antiga, 2)
        XCTAssertEqual(linhas[2].nova, 2)
    }

    // MARK: Somatórios da tela

    func testTotaisDaLista() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,2 @@
        -a
        +A
        +B
        diff --git a/b.txt b/b.txt
        --- a/b.txt
        +++ b/b.txt
        @@ -1,2 +1,1 @@
        -x
        -y
        +z
        """
        let arquivos = DiffUnificado.parse(diff)
        XCTAssertEqual(arquivos.totalDeAdicoes, 3)
        XCTAssertEqual(arquivos.totalDeRemocoes, 3)
        XCTAssertEqual(arquivos[0].nomeCurto, "a.txt")
    }

    func testNomeCurtoEPastaDeCaminhoLongo() {
        let diff = """
        diff --git a/app/CutuqueApp/GitDiffView.swift b/app/CutuqueApp/GitDiffView.swift
        --- a/app/CutuqueApp/GitDiffView.swift
        +++ b/app/CutuqueApp/GitDiffView.swift
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let arquivo = DiffUnificado.parse(diff)[0]
        XCTAssertEqual(arquivo.nomeCurto, "GitDiffView.swift")
        XCTAssertEqual(arquivo.pasta, "app/CutuqueApp")
    }

    /// Renomear sem tocar no conteúdo é o caso que o `testRenameGuardaOCaminhoAntigo`
    /// NÃO cobre: com `similarity index 100%` o git não emite `---`/`+++` nem hunk,
    /// então `rename to` é a única fonte do nome novo. Sem lê-la, os dois campos
    /// saíam iguais ao nome ANTIGO e a tela mostrava "velho.txt ← velho.txt".
    func testRenameSemMudancaDeConteudoMostraONomeNovo() {
        let diff = """
        diff --git a/velho.txt b/novo.txt
        similarity index 100%
        rename from velho.txt
        rename to novo.txt
        """
        let arquivo = DiffUnificado.parse(diff)[0]
        XCTAssertEqual(arquivo.caminho, "novo.txt")
        XCTAssertEqual(arquivo.caminhoAntigo, "velho.txt")
        XCTAssertNotEqual(arquivo.caminho, arquivo.caminhoAntigo)
    }

    func testCopySemMudancaDeConteudoMostraONomeNovo() {
        let diff = """
        diff --git a/base.txt b/copia.txt
        similarity index 100%
        copy from base.txt
        copy to copia.txt
        """
        let arquivo = DiffUnificado.parse(diff)[0]
        XCTAssertEqual(arquivo.caminho, "copia.txt")
        XCTAssertEqual(arquivo.caminhoAntigo, "base.txt")
    }

    /// A nota de "sem nova linha no fim" chega DEPOIS da última linha contada
    /// pela quota do cabeçalho. Com os dois contadores zerados ela caía fora do
    /// hunk e era descartada em silêncio — contrariando o contrato do próprio
    /// `TipoDeLinha.meta`, e fazendo o botão de copiar reconstruir um patch que
    /// afirma ter newline final quando o arquivo não tem.
    func testAvisoDeSemNovaLinhaNoFimDoHunkNaoSome() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let linhas = DiffUnificado.parse(diff)[0].hunks[0].linhas
        XCTAssertEqual(linhas.count, 3)
        XCTAssertEqual(linhas.last?.tipo, .meta)
        XCTAssertEqual(linhas.last?.texto, "\\ No newline at end of file")
        // Meta não numera de lado nenhum, senão desalinharia tudo abaixo dela.
        XCTAssertNil(linhas.last?.antiga)
        XCTAssertNil(linhas.last?.nova)
    }

    /// Editar a última linha de um arquivo sem newline final gera a marca DOS
    /// DOIS lados. A do lado antigo cabia na quota; a do lado novo é a que sumia.
    func testAvisoDeSemNovaLinhaNosDoisLados() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -velho
        \\ No newline at end of file
        +novo
        \\ No newline at end of file
        """
        let linhas = DiffUnificado.parse(diff)[0].hunks[0].linhas
        XCTAssertEqual(linhas.filter { $0.tipo == .meta }.count, 2)
        XCTAssertEqual(linhas.map(\.tipo), [.remocao, .meta, .adicao, .meta])
    }

    /// A numeração não pode ser afetada pela marca: a linha de contexto depois
    /// de um hunk com meta continua contando a partir de onde parou.
    func testMetaNaoConsomeQuotaDoHunk() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
        -velho
        \\ No newline at end of file
        +novo
         segunda
        """
        let linhas = DiffUnificado.parse(diff)[0].hunks[0].linhas
        let contexto = linhas.last
        XCTAssertEqual(contexto?.tipo, .contexto)
        XCTAssertEqual(contexto?.antiga, 2)
        XCTAssertEqual(contexto?.nova, 2)
    }
}
