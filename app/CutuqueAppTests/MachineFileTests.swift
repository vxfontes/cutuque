import XCTest
@testable import CutuqueApp

/// Modelos da aba Máquinas: a máquina em si e o navegador de arquivos. Só o que
/// não fala com a rede — o decode do que o hub manda e as regras de exibição.
final class MachineFileTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Machine

    func testMachineDecodificaOQueOHubManda() throws {
        let m: Machine = try decode(#"{"name":"macbook","dest":"vx@192.0.2.20","port":22,"source":"env"}"#)
        XCTAssertEqual(m.name, "macbook")
        XCTAssertEqual(m.dest, "vx@192.0.2.20")
        XCTAssertEqual(m.port, 22)
        XCTAssertEqual(m.id, "macbook")
    }

    /// A máquina onde o hub roda não tem ssh no meio — a UI não deve prometer
    /// conexão remota nela.
    func testMachineLocalEhReconhecida() throws {
        let local: Machine = try decode(#"{"name":"macmini","dest":"local","port":0,"source":"local"}"#)
        let remota: Machine = try decode(#"{"name":"macbook","dest":"vx@host","port":22,"source":"env"}"#)
        XCTAssertTrue(local.isLocal)
        XCTAssertFalse(remota.isLocal)
    }

    /// Porta padrão não polui a lista; porta diferente precisa aparecer (é o que
    /// distingue duas entradas para o mesmo host).
    func testMachineMostraAPortaSoQuandoNaoEhAPadrao() throws {
        let padrao: Machine = try decode(#"{"name":"a","dest":"vx@host","port":22,"source":"env"}"#)
        let outra: Machine = try decode(#"{"name":"b","dest":"vx@host","port":2222,"source":"env"}"#)
        let local: Machine = try decode(#"{"name":"c","dest":"local","port":0,"source":"local"}"#)
        XCTAssertEqual(padrao.displayDest, "vx@host")
        XCTAssertEqual(outra.displayDest, "vx@host:2222")
        XCTAssertEqual(local.displayDest, "aqui mesmo")
    }

    // MARK: - FileEntry / FileListing

    /// `is_dir` chega em snake_case; o decoder do app converte.
    func testFileEntryDecodificaIsDirEmSnakeCase() throws {
        let e: FileEntry = try decode(#"{"name":"docs","path":"/Users/vx/docs","size":0,"mtime":1700000000,"is_dir":true}"#)
        XCTAssertTrue(e.isDir)
        XCTAssertEqual(e.id, "/Users/vx/docs")
    }

    func testFileListingDecodificaPastasEArquivos() throws {
        let l: FileListing = try decode("""
        {"path":"/Users/vx","parent":"/Users","entries":[
          {"name":"docs","path":"/Users/vx/docs","size":0,"mtime":1700000000,"is_dir":true},
          {"name":"notas.md","path":"/Users/vx/notas.md","size":1024,"mtime":1700000100,"is_dir":false}
        ]}
        """)
        XCTAssertEqual(l.parent, "/Users")
        XCTAssertEqual(l.entries.count, 2)
        XCTAssertTrue(l.entries[0].isDir)
        XCTAssertEqual(l.entries[1].size, 1024)
    }

    /// Pasta não tem tamanho para mostrar (o hub manda 0) — exibir "Zero KB"
    /// seria mentira.
    func testPastaNaoTemRotuloDeTamanho() throws {
        let pasta: FileEntry = try decode(#"{"name":"docs","path":"/d","size":0,"mtime":0,"is_dir":true}"#)
        let arquivo: FileEntry = try decode(#"{"name":"a.txt","path":"/a.txt","size":2048,"mtime":0,"is_dir":false}"#)
        XCTAssertEqual(pasta.sizeLabel, "")
        XCTAssertFalse(arquivo.sizeLabel.isEmpty)
    }

    func testArquivoOcultoEhReconhecido() throws {
        let oculto: FileEntry = try decode(#"{"name":".env","path":"/.env","size":1,"mtime":0,"is_dir":false}"#)
        let normal: FileEntry = try decode(#"{"name":"env","path":"/env","size":1,"mtime":0,"is_dir":false}"#)
        XCTAssertTrue(oculto.isHidden)
        XCTAssertFalse(normal.isHidden)
    }

    /// O toggle de ocultos filtra sem reordenar (pastas antes de arquivos, como
    /// o hub mandou).
    func testFiltroDeOcultosPreservaAOrdem() throws {
        let l: FileListing = try decode("""
        {"path":"/","parent":"/","entries":[
          {"name":".git","path":"/.git","size":0,"mtime":0,"is_dir":true},
          {"name":"src","path":"/src","size":0,"mtime":0,"is_dir":true},
          {"name":".env","path":"/.env","size":1,"mtime":0,"is_dir":false},
          {"name":"a.txt","path":"/a.txt","size":1,"mtime":0,"is_dir":false}
        ]}
        """)
        XCTAssertEqual(l.visibleEntries(showHidden: false).map(\.name), ["src", "a.txt"])
        XCTAssertEqual(l.visibleEntries(showHidden: true).map(\.name), [".git", "src", ".env", "a.txt"])
    }

    // MARK: - FileContent

    func testFileContentTextoTrazOConteudo() throws {
        // Delimitador duplo: o `"#` do markdown fecharia uma raw string simples.
        let c: FileContent = try decode(##"{"path":"/a.md","size":6,"binary":false,"truncated":false,"content":"# olá\n"}"##)
        XCTAssertEqual(c.content, "# olá\n")
        XCTAssertTrue(c.isReadable)
    }

    /// Binário e acima do teto vêm sem conteúdo: a tela mostra o aviso em vez de
    /// um corpo vazio sem explicação.
    func testBinarioEtruncadoNaoSaoLegiveis() throws {
        let bin: FileContent = try decode(#"{"path":"/a.png","size":99,"binary":true,"truncated":false,"content":""}"#)
        let big: FileContent = try decode(#"{"path":"/b.log","size":99999999,"binary":false,"truncated":true,"content":""}"#)
        XCTAssertFalse(bin.isReadable)
        XCTAssertFalse(big.isReadable)
        XCTAssertEqual(bin.unreadableReason, "Arquivo binário — não dá para mostrar como texto.")
        XCTAssertEqual(big.unreadableReason, "Arquivo grande demais (acima de 1 MB) para abrir aqui.")
    }

    func testArquivoDeTextoNaoTemMotivoDeRecusa() throws {
        let c: FileContent = try decode(#"{"path":"/a.md","size":1,"binary":false,"truncated":false,"content":"x"}"#)
        XCTAssertNil(c.unreadableReason)
    }
}
