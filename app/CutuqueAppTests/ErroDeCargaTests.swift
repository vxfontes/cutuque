import XCTest
@testable import CutuqueApp

/// O portão `carregaArquivos` (fase D) fez o `.task` do navegador de arquivos
/// virar `.task(id:)`, e `.task(id:)` CANCELA o fetch em voo quando o id muda.
/// Cancelar por navegação não é falha de rede — sem esta distinção o alerta
/// "Não deu para listar" pipocava só porque a usuária trocou de painel ou de
/// aba (achado importante da revisão da fase D, 12/08/2026).
final class ErroDeCargaTests: XCTestCase {

    func testCancelamentoDeURLSessionEhCancelamento() {
        // É este o erro que `URLSession.shared.data(for:)` propaga quando a
        // Task que o hospedava é cancelada — o caso real do achado.
        XCTAssertTrue(ErroDeCarga.ehCancelamento(URLError(.cancelled)))
    }

    func testCancelamentoDeTaskEhCancelamento() {
        // O caminho estruturado: `try Task.checkCancellation()` em qualquer
        // ponto da carga lança isto, não um URLError.
        XCTAssertTrue(ErroDeCarga.ehCancelamento(CancellationError()))
    }

    func testFalhaDeRedeDeVerdadeNaoEhCancelamento() {
        // O par que dá sentido ao teste de cima: se ele passasse sozinho,
        // "ehCancelamento" poderia ser um `return true` que engole TODO erro e
        // deixaria a usuária sem aviso quando o hub realmente cai.
        XCTAssertFalse(ErroDeCarga.ehCancelamento(URLError(.timedOut)))
        XCTAssertFalse(ErroDeCarga.ehCancelamento(URLError(.cannotConnectToHost)))
        XCTAssertFalse(ErroDeCarga.ehCancelamento(URLError(.notConnectedToInternet)))
    }

    func testErroQualquerNaoEhCancelamento() {
        struct ErroDoHub: Error {}
        XCTAssertFalse(ErroDeCarga.ehCancelamento(ErroDoHub()))
    }
}
