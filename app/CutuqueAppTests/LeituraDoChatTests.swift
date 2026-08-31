import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre as duas decisões que definem "quanto contexto cabe na tela do chat":
/// o tamanho do texto e quando a tela pode se mexer sozinha.
final class EscalaDeLeituraTests: XCTestCase {
    func testPassoZeroNaoMexeNoTamanhoDoSistema() {
        for tamanho in DynamicTypeSize.allCases {
            XCTAssertEqual(EscalaDeLeitura.aplicado(tamanho, passos: 0), tamanho)
        }
    }

    func testUmPassoParaCimaEUmParaBaixoVoltamAoMesmoLugar() {
        let base = DynamicTypeSize.large
        let maior = EscalaDeLeitura.aplicado(base, passos: 1)
        XCTAssertGreaterThan(maior, base)
        XCTAssertEqual(EscalaDeLeitura.aplicado(maior, passos: -1), base)
    }

    /// O ajuste é RELATIVO ao sistema: quem configurou o aparelho em texto
    /// grande e escolhe "compacto" não cai no mesmo tamanho de quem estava no
    /// padrão — só anda os mesmos passos a partir de onde estava.
    func testAjusteERelativoAoTamanhoDoSistema() {
        let dePadrao = EscalaDeLeitura.aplicado(.large, passos: -1)
        let deGrande = EscalaDeLeitura.aplicado(.xxLarge, passos: -1)
        XCTAssertNotEqual(dePadrao, deGrande)
        XCTAssertGreaterThan(deGrande, dePadrao)
    }

    func testSaturaNasPontasSemEstourar() {
        XCTAssertEqual(EscalaDeLeitura.aplicado(.xSmall, passos: -3), .xSmall)
        let maior = DynamicTypeSize.allCases.last!
        XCTAssertEqual(EscalaDeLeitura.aplicado(maior, passos: 3), maior)
    }

    func testPassosForaDaFaixaSaoAparados() {
        XCTAssertEqual(EscalaDeLeitura.dentroDaFaixa(99), EscalaDeLeitura.maximo)
        XCTAssertEqual(EscalaDeLeitura.dentroDaFaixa(-99), EscalaDeLeitura.minimo)
        XCTAssertEqual(EscalaDeLeitura.dentroDaFaixa(2), 2)
        // Pedir mais que o máximo não pode virar mais que o máximo por outra via.
        XCTAssertEqual(EscalaDeLeitura.aplicado(.large, passos: 99),
                       EscalaDeLeitura.aplicado(.large, passos: EscalaDeLeitura.maximo))
    }

    func testBotoesDesligamNasPontas() {
        XCTAssertFalse(EscalaDeLeitura.podeAumentar(EscalaDeLeitura.maximo))
        XCTAssertTrue(EscalaDeLeitura.podeAumentar(EscalaDeLeitura.maximo - 1))
        XCTAssertFalse(EscalaDeLeitura.podeDiminuir(EscalaDeLeitura.minimo))
        XCTAssertTrue(EscalaDeLeitura.podeDiminuir(EscalaDeLeitura.minimo + 1))
    }

    func testRotuloDizOQueEstaValendo() {
        XCTAssertEqual(EscalaDeLeitura.rotulo(0), "Tamanho do sistema")
        XCTAssertTrue(EscalaDeLeitura.rotulo(-2).contains("Compacto"))
        XCTAssertTrue(EscalaDeLeitura.rotulo(2).contains("+2"))
    }

    /// As duas chaves precisam ser diferentes — é o que faz o iPhone poder
    /// ficar compacto sem arrastar o iPad junto.
    func testChavesSeparadasPorAparelho() {
        XCTAssertNotEqual(EscalaDeLeitura.chaveTelefone, EscalaDeLeitura.chaveTablet)
    }
}

final class RolagemDoTranscritoTests: XCTestCase {
    func testFimVisivelQuandoCabeNaJanela() {
        XCTAssertTrue(RolagemDoTranscrito.estaNoFim(fimY: 400, altura: 800))
        XCTAssertTrue(RolagemDoTranscrito.estaNoFim(fimY: 800, altura: 800))
    }

    /// A folga existe para rolagem elástica e arredondamento não passarem por
    /// "a usuária subiu" — a diferença entre acompanhar e roubar a tela.
    func testFolgaAbsorveQuiqueDeRolagem() {
        XCTAssertTrue(RolagemDoTranscrito.estaNoFim(fimY: 800 + RolagemDoTranscrito.folga, altura: 800))
        XCTAssertFalse(RolagemDoTranscrito.estaNoFim(fimY: 800 + RolagemDoTranscrito.folga + 1, altura: 800))
    }

    func testQuemSubiuNaoEArrastadoDeVolta() {
        XCTAssertFalse(RolagemDoTranscrito.deveAcompanhar(estavaNoFim: false))
        XCTAssertTrue(RolagemDoTranscrito.deveAcompanhar(estavaNoFim: true))
    }

    func testAvisoSoApareceComCoisaNova() {
        XCTAssertNil(RolagemDoTranscrito.aviso(naoLidas: 0))
        XCTAssertNil(RolagemDoTranscrito.aviso(naoLidas: -1))
        XCTAssertEqual(RolagemDoTranscrito.aviso(naoLidas: 7), "7")
        XCTAssertEqual(RolagemDoTranscrito.aviso(naoLidas: 99), "99")
        XCTAssertEqual(RolagemDoTranscrito.aviso(naoLidas: 100), "99+")
        XCTAssertEqual(RolagemDoTranscrito.aviso(naoLidas: 5000), "99+")
    }
}

final class TamanhoDeCodigoTests: XCTestCase {
    func testAjusteNuncaSaiDaFaixa() {
        var tamanho = TamanhoDeCodigo.padrao(pad: false)
        for _ in 0..<50 { tamanho = TamanhoDeCodigo.ajustado(tamanho, por: TamanhoDeCodigo.passo) }
        XCTAssertEqual(tamanho, TamanhoDeCodigo.maximo)
        for _ in 0..<100 { tamanho = TamanhoDeCodigo.ajustado(tamanho, por: -TamanhoDeCodigo.passo) }
        XCTAssertEqual(tamanho, TamanhoDeCodigo.minimo)
    }

    func testPadraoDoTabletEMaiorQueODoTelefone() {
        XCTAssertGreaterThan(TamanhoDeCodigo.padrao(pad: true), TamanhoDeCodigo.padrao(pad: false))
        XCTAssertNotEqual(TamanhoDeCodigo.chaveTelefone, TamanhoDeCodigo.chaveTablet)
    }

    func testBotoesDesligamNasPontas() {
        XCTAssertFalse(TamanhoDeCodigo.podeAumentar(TamanhoDeCodigo.maximo))
        XCTAssertFalse(TamanhoDeCodigo.podeDiminuir(TamanhoDeCodigo.minimo))
        XCTAssertTrue(TamanhoDeCodigo.podeAumentar(TamanhoDeCodigo.padrao(pad: false)))
        XCTAssertTrue(TamanhoDeCodigo.podeDiminuir(TamanhoDeCodigo.padrao(pad: false)))
    }

    /// A largura sustenta o fundo colorido da linha do diff quando a quebra
    /// está desligada: errar para MENOS cortaria o fundo antes do fim do texto.
    func testLarguraSobraEmVezDeFaltar() {
        let tamanho = 12.0
        let largura = TamanhoDeCodigo.larguraDeTexto(colunas: 80, tamanho: tamanho)
        XCTAssertGreaterThan(largura, 80 * tamanho * TamanhoDeCodigo.razaoDeAvanco)
        XCTAssertGreaterThan(TamanhoDeCodigo.larguraDeTexto(colunas: 120, tamanho: tamanho), largura)
        XCTAssertGreaterThan(TamanhoDeCodigo.larguraDeTexto(colunas: 80, tamanho: 20), largura)
    }

    func testLarguraDeArquivoVazioNaoENegativa() {
        XCTAssertGreaterThan(TamanhoDeCodigo.larguraDeTexto(colunas: 0, tamanho: 11), 0)
    }
}
