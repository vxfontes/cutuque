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

    /// O caso que mais importa aqui é o `.zip`: `TipoDeArquivo.abreNoPreview`
    /// exclui `.outro` de propósito (quem identifica zip/.docx é o `binary` do
    /// hub, não a extensão — comentário em `TipoDeArquivo.swift`), então usar
    /// `abreNoPreview` puro no visualizador binário deixaria zip SEM preview.
    /// `abreNoQuickLook` é o que corrige isso — é o ponto que este teste tranca.
    func testTipoDeArquivoRoteiaParaOQuickLook() {
        for nome in ["ferias.mov", "foto.png", "contrato.pdf", "retrato.heic", "backup.zip"] {
            XCTAssertTrue(TipoDeArquivo.de(nome: nome).abreNoQuickLook, nome)
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
        XCTAssertTrue(TipoDeArquivo.de(nome: semExtensao.name).abreNoQuickLook)
        XCTAssertFalse(VisualizadorBinario.devePedirConfirmacao(tamanho: semExtensao.size))
        XCTAssertFalse(semExtensao.sizeLabel.isEmpty)
    }

    func testNomeVazioNaoQuebra() {
        XCTAssertTrue(TipoDeArquivo.de(nome: "").abreNoQuickLook)
    }
}
