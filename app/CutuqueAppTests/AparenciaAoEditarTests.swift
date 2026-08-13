import XCTest
@testable import CutuqueApp

/// O `PATCH` desta tela manda `theme: ""` e "" significa MANTÉM — ele não sabe
/// dizer "volta ao padrão". Era a razão de aparência não existir ao editar
/// (comentário de 12/08). A razão continua verdadeira: o que muda é que a tela
/// passa a chamar TAMBÉM o `PUT /appearance`, que sabe. (13/08/2026)
final class AparenciaAoEditarTests: XCTestCase {
    func testNaoChamaAppearanceQuandoNadaMudou() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "dracula", iconeEscolhido: "server")
        XCTAssertNil(d)
    }

    func testVoltarAoPadraoEnviaVazio() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "", iconeEscolhido: "")
        XCTAssertEqual(d?.tema, "")
        XCTAssertEqual(d?.icone, "")
    }

    /// O PUT leva os DOIS campos sempre: mandar só o que mudou apagaria o outro
    /// (vazio é escolha no `/appearance`, não "mantém").
    func testMudarSoOIconeAindaEnviaOTemaAtual() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "",
                                                temaEscolhido: "dracula", iconeEscolhido: "laptop")
        XCTAssertEqual(d?.tema, "dracula")
        XCTAssertEqual(d?.icone, "laptop")
    }
}
