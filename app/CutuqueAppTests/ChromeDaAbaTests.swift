import Combine
import XCTest
@testable import CutuqueApp

/// O registro que a `ChromeDaAba` lê: quais segmentos cada aba tem e qual está
/// escolhido.
///
/// [13/08/2026] Existe porque o seletor de painel morava em
/// `ToolbarItem(placement: .principal)` DENTRO de cada painel — e, pela decisão
/// #19, N painéis ficam montados para sempre no `ZStack` do iPad. N painéis
/// contribuindo para a MESMA navigation bar faz o SwiftUI esconder quase todos:
/// era a causa de "não ta aparecendo o terminal / info embaixo da aba".
@MainActor
final class ChromeDaAbaTests: XCTestCase {
    private let sessao = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "cutuque\t%3")
    private let maquina = ChaveDeAba(tipo: .maquina, machine: "macmini", alvo: "macmini")

    private let tresDaSessao = [
        SegmentoDeChrome(id: "chat", titulo: "Chat", simbolo: "bubble.left"),
        SegmentoDeChrome(id: "terminal", titulo: "Terminal", simbolo: "apple.terminal"),
        SegmentoDeChrome(id: "info", titulo: "Info", simbolo: "info.circle"),
    ]

    func testSegmentosFicamPorAba() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: sessao)
        XCTAssertEqual(nav.segmentos(de: sessao).map(\.id), ["chat", "terminal", "info"])
        // A aba da máquina não herda os segmentos da sessão: as duas ficam
        // MONTADAS ao mesmo tempo, e era exatamente essa mistura que escondia o
        // seletor na toolbar.
        XCTAssertTrue(nav.segmentos(de: maquina).isEmpty)
    }

    func testEscolhaNaoVazaEntreAbas() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: sessao)
        nav.escolher("terminal", de: sessao)
        XCTAssertEqual(nav.escolha(de: sessao), "terminal")
        XCTAssertNil(nav.escolha(de: maquina))
    }

    /// iPhone (sem abas) e qualquer leitor que passe `nil` não podem receber o
    /// registro de aba nenhuma — mesmo contrato de `paneMode(de: nil)`.
    func testSemAbaNaoTemSegmentoNemEscolha() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: sessao)
        XCTAssertTrue(nav.segmentos(de: nil).isEmpty)
        XCTAssertNil(nav.escolha(de: nil))
    }

    /// Sem isto o registro cresce para sempre e uma aba reaberta acha segmento
    /// velho de conteúdo que já não existe.
    func testLimparRemoveSegmentosEEscolha() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: sessao)
        nav.escolher("info", de: sessao)
        nav.limparChrome(de: sessao)
        XCTAssertTrue(nav.segmentos(de: sessao).isEmpty)
        XCTAssertNil(nav.escolha(de: sessao))
    }

    func testLimparNaoMexeNasOutrasAbas() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao, de: sessao)
        nav.definirSegmentos([SegmentoDeChrome(id: "terminal", titulo: "Terminal", simbolo: "apple.terminal")],
                             de: maquina)
        nav.escolher("terminal", de: maquina)
        nav.limparChrome(de: sessao)
        XCTAssertEqual(nav.segmentos(de: maquina).map(\.id), ["terminal"])
        XCTAssertEqual(nav.escolha(de: maquina), "terminal")
    }

    /// Escrever o MESMO valor não pode publicar mudança: os painéis chamam
    /// `definirSegmentos` de `.task`/`.onChange`, que rodam a cada recomposição —
    /// publicar valor igual é laço de atualização de view.
    func testDefinirIgualNaoPublica() {
        let nav = NavigationState()
        var avisos = 0
        let cancelavel = nav.objectWillChange.sink { _ in avisos += 1 }
        nav.definirSegmentos(tresDaSessao, de: sessao)
        let depoisDaPrimeira = avisos
        XCTAssertGreaterThan(depoisDaPrimeira, 0, "a primeira escrita PRECISA publicar")
        nav.definirSegmentos(tresDaSessao, de: sessao)
        XCTAssertEqual(avisos, depoisDaPrimeira, "definirSegmentos com valor igual não pode publicar")
        cancelavel.cancel()
    }

    func testEscolherIgualNaoPublica() {
        let nav = NavigationState()
        nav.escolher("terminal", de: sessao)
        var avisos = 0
        let cancelavel = nav.objectWillChange.sink { _ in avisos += 1 }
        nav.escolher("terminal", de: sessao)
        XCTAssertEqual(avisos, 0, "escolher com valor igual não pode publicar")
        cancelavel.cancel()
    }

    /// A ordem dos segmentos é a ordem que o painel declarou — a chrome desenha
    /// na sequência, e Chat/Terminal/Info não é alfabético.
    func testOrdemDeclaradaEPreservada() {
        let nav = NavigationState()
        nav.definirSegmentos(tresDaSessao.reversed(), de: sessao)
        XCTAssertEqual(nav.segmentos(de: sessao).map(\.id), ["info", "terminal", "chat"])
    }
}
