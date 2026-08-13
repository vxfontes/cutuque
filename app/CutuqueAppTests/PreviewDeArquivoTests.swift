import XCTest
@testable import CutuqueApp

/// Testes puros do lado binário do preview de arquivos (12/08/2026): o teto de
/// download decide certo nas bordas, e o QuickLook cobre tudo que chega ao
/// `VisualizadorBinario` — inclusive o que `TipoDeArquivo.abreNoPreview` deixa
/// de fora de propósito (zip, .docx). Sem simulador de UI: só as regras que dá
/// para testar sem montar a view.
final class PreviewDeArquivoTests: XCTestCase {

    // MARK: - Teto de download (bordas)

    func testTetoDecideNasBordas() {
        let teto = LimitesDeArquivo.tetoDePreview // 50 MiB, 52_428_800 bytes

        // ~49,9 MB: dentro do teto, baixa sozinho.
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: teto - 1))
        // Exatamente 50 MB: a regra é "≤ teto baixa sozinho" (spec, "O teto de
        // 50 MB"), então a borda de cima ainda inclui o limite exato.
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: teto))
        // ~50,1 MB: passou do teto, precisa do toque em "Baixar assim mesmo".
        XCTAssertTrue(VisualizadorBinario.devePedirConfirmacao(tamanho: teto + 1))
    }

    /// Mesma regra, com tamanhos redondos — lembrando que o teto é 50 MiB
    /// (52_428_800 bytes), não 50 milhões de bytes decimais: 51 MB decimais
    /// (51_000_000) ainda cabem dentro dos 50 MiB, só 53 MB já passam.
    func testTetoComTamanhosRedondos() {
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: 49_900_000)) // 49,9 MB, dentro
        XCTAssertTrue(VisualizadorBinario.devePedirConfirmacao(tamanho: 53_000_000)) // 53 MB, passou dos 50 MiB (52_428_800 bytes)
    }

    // MARK: - Roteamento para o QuickLook

    /// O `VisualizadorBinario` manda tudo para o QuickLook sem olhar o tipo, de
    /// propósito (decisão #1) — então não há gate para testar. O que dá para
    /// trancar é a armadilha: quem um dia tentar rotear por tipo vai buscar
    /// `abreNoPreview`, e ele é FALSO justo para os arquivos que mais precisam
    /// do QuickLook. `.zip` e `.docx` caem em `.outro` porque quem os identifica
    /// é o `binary` do hub, não a extensão (comentário em `TipoDeArquivo.swift`).
    /// Este teste existe para essa asserção falhar barulhenta se alguém achar
    /// que `abreNoPreview` serve de gate ali.
    func testAbreNoPreviewNaoServeDeGateNoVisualizadorBinario() {
        for nome in ["backup.zip", "contrato.docx"] {
            XCTAssertEqual(TipoDeArquivo.de(nome: nome), .outro, nome)
            XCTAssertFalse(TipoDeArquivo.de(nome: nome).abreNoPreview, nome)
        }
        // Os que o `abreNoPreview` cobre continuam cobertos — o campo não está
        // errado, só é estreito demais para servir de gate no binário.
        for nome in ["ferias.mov", "foto.png", "contrato.pdf", "retrato.heic"] {
            XCTAssertTrue(TipoDeArquivo.de(nome: nome).abreNoPreview, nome)
        }
    }

    // MARK: - Nome sem extensão

    /// `Makefile` cai em `.outro` (`TipoDeArquivoTests` já cobre o
    /// roteamento) — o que importa aqui é que o visualizador binário não
    /// quebra com ele: ainda decide o teto e ainda manda para o QuickLook sem
    /// exceção nenhuma.
    func testNomeSemExtensaoNaoQuebraNoVisualizadorBinario() throws {
        let semExtensao: FileEntry = try JSONDecoder.cutuque.decode(
            FileEntry.self,
            from: Data(#"{"name":"Makefile","path":"/proj/Makefile","size":1024,"mtime":0,"is_dir":false}"#.utf8)
        )
        XCTAssertEqual(TipoDeArquivo.de(nome: semExtensao.name), .outro)
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: semExtensao.size))
        XCTAssertFalse(semExtensao.sizeLabel.isEmpty)
    }

    /// Nome vazio não é hipótese de laboratório: o hub devolve o que o `ls`
    /// deu, e um `name` vazio não pode virar crash no caminho do preview.
    func testNomeVazioNaoQuebra() {
        XCTAssertEqual(TipoDeArquivo.de(nome: ""), .outro)
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: 0))
    }
}
