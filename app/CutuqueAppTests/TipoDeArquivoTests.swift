import XCTest
@testable import CutuqueApp

/// O vocabulário compartilhado da leva do preview (12/08/2026): que tipo cada
/// nome de arquivo tem, quais tetos valem e como a cauda muda o que a tela pode
/// fazer com o conteúdo.
final class TipoDeArquivoTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Roteamento por extensão

    func testMidiaVaiParaOPreview() {
        for nome in ["foto.png", "ferias.MOV", "podcast.m4a", "contrato.pdf", "icone.svg"] {
            XCTAssertTrue(TipoDeArquivo.de(nome: nome).abreNoPreview, nome)
        }
    }

    func testTextoNaoVaiParaOPreview() {
        for nome in ["leia.md", "dados.json", "app.ts", "saida.log", "Makefile"] {
            XCTAssertFalse(TipoDeArquivo.de(nome: nome).abreNoPreview, nome)
        }
    }

    func testExtensaoEmMaiusculaContaIgual() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "FOTO.PNG"), .imagem)
        XCTAssertEqual(TipoDeArquivo.de(nome: "LEIA.MD"), .markdown)
    }

    func testMarkdownEJsonTemCasoProprio() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "README.md"), .markdown)
        XCTAssertEqual(TipoDeArquivo.de(nome: "package.json"), .json)
    }

    func testCodigoVemComALinguagem() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "App.tsx"), .texto(.typescript))
        XCTAssertEqual(TipoDeArquivo.de(nome: "main.go"), .texto(.go))
        XCTAssertEqual(TipoDeArquivo.de(nome: "View.swift"), .texto(.swift))
        XCTAssertEqual(TipoDeArquivo.de(nome: "deploy.sh"), .texto(.shell))
        XCTAssertEqual(TipoDeArquivo.de(nome: "docker-compose.yml"), .texto(.yaml))
    }

    func testTextoSemLinguagemConhecidaAindaEhTexto() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "saida.log"), .texto(nil))
        XCTAssertEqual(TipoDeArquivo.de(nome: "notas.txt"), .texto(nil))
    }

    /// Sem extensão cai em `.outro` de propósito: `Makefile` é texto e um
    /// executável não é, e a extensão não distingue os dois — quem distingue é
    /// o `binary` do hub. Cair em `.outro` é o que mantém essa decisão com quem
    /// sabe dela.
    func testNomeSemExtensaoNaoQuebraECaiEmOutro() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "Makefile"), .outro)
        XCTAssertEqual(TipoDeArquivo.de(nome: ".gitignore"), .outro)
        XCTAssertEqual(TipoDeArquivo.de(nome: ""), .outro)
    }

    func testExtensaoDesconhecidaCaiEmOutro() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "backup.zip"), .outro)
        XCTAssertEqual(TipoDeArquivo.de(nome: "arquivo.qualquercoisa"), .outro)
    }

    func testLinguagemDoFonteCobreMarkdownEJson() {
        XCTAssertEqual(TipoDeArquivo.de(nome: "a.md").linguagemDoFonte, .markdown)
        XCTAssertEqual(TipoDeArquivo.de(nome: "a.json").linguagemDoFonte, .json)
        XCTAssertEqual(TipoDeArquivo.de(nome: "a.rs").linguagemDoFonte, .rust)
        XCTAssertNil(TipoDeArquivo.de(nome: "a.log").linguagemDoFonte)
        XCTAssertNil(TipoDeArquivo.de(nome: "foto.png").linguagemDoFonte)
    }

    // MARK: - Tetos

    func testTetoDePreviewSaoOs50MB() {
        XCTAssertEqual(LimitesDeArquivo.tetoDePreview, 52_428_800)
        XCTAssertEqual(LimitesDeArquivo.tetoDeRealce, 204_800)
    }

    // MARK: - Cauda

    /// A garantia que impede a tela de parar de funcionar contra o hub de
    /// produção: o campo `tail` ainda não existe lá, e a ausência dele não pode
    /// derrubar o decode.
    func testDecodeSemOCampoTailNaoQuebra() throws {
        let c: FileContent = try decode(#"{"path":"/a.md","size":6,"binary":false,"truncated":false,"content":"oi"}"#)
        XCTAssertNil(c.tail)
        XCTAssertFalse(c.ehCauda)
        XCTAssertTrue(c.isReadable)
        XCTAssertTrue(c.podeMostrarTexto)
    }

    func testCaudaMostraTextoMasNaoDeixaEditar() throws {
        let c: FileContent = try decode(#"{"path":"/b.log","size":5242880,"binary":false,"truncated":true,"tail":true,"content":"fim"}"#)
        XCTAssertTrue(c.ehCauda)
        XCTAssertTrue(c.podeMostrarTexto)
        XCTAssertFalse(c.isReadable)
        XCTAssertNil(c.unreadableReason)
    }

    func testGrandeSemCaudaContinuaSemTexto() throws {
        let c: FileContent = try decode(#"{"path":"/b.log","size":5242880,"binary":false,"truncated":true,"content":""}"#)
        XCTAssertFalse(c.podeMostrarTexto)
        XCTAssertNotNil(c.unreadableReason)
    }

    func testBinarioNuncaViraCauda() throws {
        let c: FileContent = try decode(#"{"path":"/a.png","size":99,"binary":true,"truncated":false,"content":""}"#)
        XCTAssertFalse(c.podeMostrarTexto)
        XCTAssertFalse(c.isReadable)
        XCTAssertEqual(c.unreadableReason, "Arquivo binário — não dá para mostrar como texto.")
    }

    // MARK: - Realçador (contrato, antes do tokenizador existir)

    /// Vale enquanto o corpo é neutro E depois que ele colorir: o realce nunca
    /// pode perder caractere.
    func testRealceNaoPerdeCaractere() {
        let fonte = "let x = 1 // conta\nprint(\"oi\")\n"
        let saida = RealceDeSintaxe.aplicar(fonte, linguagem: .swift)
        XCTAssertEqual(String(saida.characters), fonte)
    }

    func testRealceDeTextoVazioNaoQuebra() {
        XCTAssertEqual(String(RealceDeSintaxe.aplicar("", linguagem: nil).characters), "")
    }
}
