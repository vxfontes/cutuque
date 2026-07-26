import SwiftUI
import XCTest
@testable import CutuqueApp

@MainActor
final class NavigationStateTests: XCTestCase {

    func testComecaNasSessoesComTresColunas() {
        let nav = NavigationState()
        XCTAssertEqual(nav.destination, .sessions)
        XCTAssertEqual(nav.columnVisibility, .all)
        XCTAssertEqual(nav.paneMode, .chat)
        XCTAssertNil(nav.selection)
    }

    func testChatNaoDisputaLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .chat
        XCTAssertFalse(nav.wantsWidth)
    }

    func testTerminalEBoardDisputamLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .terminal
        XCTAssertTrue(nav.wantsWidth)

        nav.destination = .board
        nav.paneMode = .chat
        XCTAssertTrue(nav.wantsWidth)
    }

    func testExpandirEhReversivel() {
        let nav = NavigationState()
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testRegraDe700AbreExpandidoNoDetalheEstreito() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyWidthRule(detailWidth: 554)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
    }

    func testRegraDe700MantemTresColunasNoDetalheLargo() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyWidthRule(detailWidth: 806)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testRegraDe700NaoExpandeODestinoQueNaoPedeLargura() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.paneMode = .chat
        nav.applyWidthRule(detailWidth: 400)   // estreitíssimo, mas é chat
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testIntentEhConsumidoUmaVezSo() {
        let nav = NavigationState()
        nav.send(.reload)
        XCTAssertEqual(nav.intent, .reload)
        nav.consume()
        XCTAssertNil(nav.intent)
    }

    /// A lista de sessões e o detalhe estão vivos ao mesmo tempo em colunas
    /// diferentes. Se um consumidor que NÃO reconhece o intent chamar
    /// `consume()` mesmo assim, ele engole o atalho que era do vizinho. O
    /// contrato certo é: espiar `intent`, só chamar `consume()` quando o caso
    /// é reconhecido — e aqui simulamos exatamente essa disciplina de dois
    /// consumidores concorrentes.
    func testConsumidorQueNaoReconheceOIntentNaoOConsome() {
        let nav = NavigationState()
        nav.send(.moveCardLeft)

        // Consumidor A (ex.: lista de sessões) só trata .selectSession — não
        // reconhece .moveCardLeft, então não deve chamar consume().
        if case .selectSession = nav.intent {
            nav.consume()
        }
        XCTAssertEqual(nav.intent, .moveCardLeft, "consumidor que não reconhece o intent não pode limpá-lo")

        // Consumidor B (ex.: board) reconhece .moveCardLeft e consome.
        if case .moveCardLeft = nav.intent {
            nav.consume()
        }
        XCTAssertNil(nav.intent)
    }

    func testTodoDestinoTemRotuloESimbolo() {
        for d in PadDestination.allCases {
            XCTAssertFalse(d.label.isEmpty)
            XCTAssertFalse(d.symbol.isEmpty)
        }
    }

    // MARK: - consumeIfInterrupt (Task 15, correção do achado de testabilidade)
    //
    // `SessionDetailView` reduz seu `.onChange(of: nav.intent)` a fiação
    // trivial que chama este método. A regra "só consome .interrupt, nunca em
    // default:" é o que protege o vizinho (a lista de sessões, viva na outra
    // coluna) de ter seus intents engolidos — por isso testada aqui, direto
    // na NavigationState, sem qualquer hosting de View.

    func testConsumeIfInterruptConsomeQuandoIntentEhInterrupt() {
        let nav = NavigationState()
        nav.send(.interrupt)

        let consumiu = nav.consumeIfInterrupt()

        XCTAssertTrue(consumiu)
        XCTAssertNil(nav.intent)
    }

    func testConsumeIfInterruptNaoConsomeIntentDiferente() {
        let nav = NavigationState()
        nav.send(.moveCardLeft)

        let consumiu = nav.consumeIfInterrupt()

        XCTAssertFalse(consumiu)
        XCTAssertEqual(nav.intent, .moveCardLeft, "intent de outro consumidor não pode ser engolido")
    }

    func testConsumeIfInterruptNaoConsomeIntentNil() {
        let nav = NavigationState()
        XCTAssertNil(nav.intent)

        let consumiu = nav.consumeIfInterrupt()

        XCTAssertFalse(consumiu)
        XCTAssertNil(nav.intent)
    }

    /// Card aberto no inspector do board (Task 13) — alimentado também pela
    /// busca da coluna do meio, que fica num arquivo separado do `BoardView`
    /// e por isso precisa de um estado compartilhado pra abrir o card nele.
    func testBoardSelectionComecaNilEEhAlimentavelPelaBusca() {
        let nav = NavigationState()
        XCTAssertNil(nav.boardSelection)
        let json = """
        {"id":"x","title":"t","column":"a_fazer","group":"g","session":"s"}
        """
        let task = try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
        nav.boardSelection = task
        XCTAssertEqual(nav.boardSelection?.id, "x")
    }
}
