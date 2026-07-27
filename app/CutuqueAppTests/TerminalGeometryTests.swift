import XCTest
import SwiftUI
@testable import CutuqueApp

final class TerminalGeometryTests: XCTestCase {

    /// Métricas dos 13 pt padrão do iPad, MEDIDAS no simulador com
    /// `ImageRenderer` (ver `testReguaBateComOTextoQueOSwiftUIDesenha`, que
    /// amarra estes números ao layout de verdade em vez de deixá-los como mais
    /// um literal solto).
    private static let pad13 = TerminalGeometry.TextMetrics(charWidth: 8.04, lineHeight: 16)
    /// Idem pros 10 pt padrão do iPhone. A altura de linha aqui é 12, não
    /// 12.8 (o que a razão antiga de 1.28 supunha) nem 13 (o que o mesmo
    /// texto mede no macOS).
    private static let phone10 = TerminalGeometry.TextMetrics(charWidth: 6.19, lineHeight: 12)

    // MARK: Colunas

    /// A largura não muda de resultado com esta correção — a razão antiga
    /// (0.62) já era a certa (0.6190 medido). Os três casos abaixo continuam
    /// dando o mesmo número de sempre, de propósito: é a prova de que o
    /// espelho não ficou mais estreito na troca.
    func testColunasNoIPhoneComFonteDeHoje() {
        // iPhone 15 Pro em retrato: (393 - 8*2) / 6.19 = 60.9
        XCTAssertEqual(TerminalGeometry.columns(width: 393, metrics: Self.phone10), 60)
    }

    func testColunasNoIPadExpandidoComFonteDoIPad() {
        // 11" expandido: (1194 - 16) / 8.04 = 146.5
        XCTAssertEqual(TerminalGeometry.columns(width: 1194, metrics: Self.pad13), 146)
    }

    func testColunasNoIPadEmTresColunas() {
        // detalhe de 726 pt: (726 - 16) / 8.04 = 88.3
        XCTAssertEqual(TerminalGeometry.columns(width: 726, metrics: Self.pad13), 88)
    }

    func testColunasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.columns(width: 100, metrics: Self.pad13), 30)
    }

    // MARK: Linhas

    /// O ganho concreto, isolado da mudança de cromo: para a MESMA altura
    /// útil de texto, quantas linhas cada conta pede.
    ///
    /// - antiga: 714 / (13 × 1.28 = 16.64) = 42 linhas
    /// - nova:   714 / 16 (medido)         = 44 linhas
    ///
    /// Quase 5% de conteúdo que estava sendo pedido a menos ao tmux — sem
    /// contar o que o `verticalChrome = 120` tirava por cima, que agora nem
    /// entra na conta porque a altura vem do viewport medido.
    func testLinhasComAAlturaMedidaDaLinha() {
        let alturaUtil: CGFloat = 714 + TerminalGeometry.verticalTextPadding * 2
        XCTAssertEqual(TerminalGeometry.rows(height: alturaUtil, metrics: Self.pad13), 44)
    }

    /// O iPhone ganha ainda mais que o iPad: 12.8 supostos contra 12 reais.
    /// A mesma altura útil rende 5 linhas a mais numa tela de telefone.
    func testLinhasNoIPhoneGanhamComAMedicao() {
        let alturaUtil: CGFloat = 600 + TerminalGeometry.verticalTextPadding * 2
        XCTAssertEqual(TerminalGeometry.rows(height: alturaUtil, metrics: Self.phone10), 50)
        // A conta antiga daria Int(600 / 12.8) = 46.
    }

    func testLinhasNuncaCaemAbaixoDoPiso() {
        XCTAssertEqual(TerminalGeometry.rows(height: 130, metrics: Self.pad13), 20)
    }

    // MARK: Métricas

    /// Sem medição válida não se inventa métrica — `init?` devolve `nil` e a
    /// view não pede resize nenhum. Sem este guard, uma altura zero viraria
    /// divisão por zero e `Int(inf)` derruba o app (não devolve número
    /// grande).
    func testMetricaNaoNasceDeMedidaVazia() {
        XCTAssertNil(TerminalGeometry.TextMetrics(sampleSize: .zero))
        XCTAssertNil(TerminalGeometry.TextMetrics(sampleSize: CGSize(width: 800, height: 0)))
        XCTAssertNil(TerminalGeometry.TextMetrics(sampleSize: CGSize(width: 0, height: 16)))
    }

    /// A régua divide pela amostra inteira porque o SwiftUI arredonda a
    /// largura da LINHA, não a de cada caractere.
    func testMetricaDivideAAmostraPeloComprimento() throws {
        let m = try XCTUnwrap(TerminalGeometry.TextMetrics(
            sampleSize: CGSize(width: 804, height: 16)))
        XCTAssertEqual(m.charWidth, 8.04, accuracy: 0.0001)
        XCTAssertEqual(m.lineHeight, 16, accuracy: 0.0001)
        XCTAssertTrue(m.isUsable)
    }

    /// Com métrica inválida as duas contas caem no piso em vez de dividir por
    /// zero.
    func testGradeCaiNoPisoComMetricaInvalida() {
        let ruim = TerminalGeometry.TextMetrics(charWidth: 0, lineHeight: 0)
        XCTAssertEqual(TerminalGeometry.columns(width: 1194, metrics: ruim), 30)
        XCTAssertEqual(TerminalGeometry.rows(height: 834, metrics: ruim), 20)
    }

    // MARK: A régua contra o layout de verdade

    /// O teste que justifica a mudança inteira: renderiza o MESMO `Text` que a
    /// régua da `TerminalMirrorView` renderiza e confere que
    /// `TextMetrics(sampleSize:)` descreve o que o SwiftUI de fato desenhou.
    ///
    /// Também é aqui que se vê por que a razão fixa não servia: a altura de
    /// linha dividida pelo corpo da fonte NÃO dá o mesmo número em tamanhos
    /// diferentes (medido no iOS: 1.20 em 10 pt, 1.2727 em 11 pt, 1.2308 em
    /// 13 pt, 1.25 em 16 pt — sobe e desce, sem monotonia), então nenhuma
    /// constante única acerta os dois padrões do app ao mesmo tempo.
    @MainActor
    func testReguaBateComOTextoQueOSwiftUIDesenha() throws {
        for pt in [10.0, 13.0] as [CGFloat] {
            let amostra = Text(String(repeating: "M", count: TerminalGeometry.sampleLength))
                .font(.system(size: pt, design: .monospaced))
                .fixedSize()
            let tamanho = try XCTUnwrap(ImageRenderer(content: amostra).uiImage?.size)
            let m = try XCTUnwrap(TerminalGeometry.TextMetrics(sampleSize: tamanho))

            // Uma linha só: a altura da amostra é a altura de UMA linha.
            let umaLinha = Text("M").font(.system(size: pt, design: .monospaced)).fixedSize()
            let alturaDeUma = try XCTUnwrap(ImageRenderer(content: umaLinha).uiImage?.size.height)
            XCTAssertEqual(m.lineHeight, alturaDeUma, accuracy: 0.5,
                           "a régua de \(pt) pt deveria medir a altura de uma linha")

            // A largura por caractere bate com o avanço do glifo (0.6182 × pt),
            // com folga pro arredondamento da linha inteira.
            XCTAssertEqual(m.charWidth, pt * 0.6182, accuracy: 0.05,
                           "largura por caractere errada em \(pt) pt")

            // E bate com a métrica que os testes puros acima usam — é isto
            // que impede `pad13`/`phone10` de virarem literais órfãos que
            // ninguém confere.
            let esperada = pt == 13 ? Self.pad13 : Self.phone10
            XCTAssertEqual(m.lineHeight, esperada.lineHeight, accuracy: 0.01,
                           "a altura de linha medida em \(pt) pt mudou")
            XCTAssertEqual(m.charWidth, esperada.charWidth, accuracy: 0.01,
                           "a largura de caractere medida em \(pt) pt mudou")
        }
    }
}
