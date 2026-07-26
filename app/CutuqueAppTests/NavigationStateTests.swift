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

    // MARK: - consumeSessionListIntent (Task 11, correção do achado de testabilidade)
    //
    // `SessionListView.handleAppIntent` reduz seu `.onChange(of: nav.intent)`
    // a fiação trivial em cima deste método. A lista de sessões e o painel
    // de detalhe vivem ao mesmo tempo, em colunas diferentes da split view
    // do iPad — os dois escutam `nav.intent`. Sem travar aqui a regra "só
    // consome o que reconheço", um refactor que trocasse o `default: return`
    // da View por um `consume()` passaria a suíte inteira e engoliria em
    // silêncio o ⌘. (Task 15) e o ⌘←/⌘→ (Task 14), que não são desta lista.

    func testConsumeSessionListIntentConsomeNewSession() {
        let nav = NavigationState()
        nav.send(.newSession)

        let acao = nav.consumeSessionListIntent()

        XCTAssertEqual(acao, .newSession)
        XCTAssertNil(nav.intent)
    }

    func testConsumeSessionListIntentConsomeReload() {
        let nav = NavigationState()
        nav.send(.reload)

        let acao = nav.consumeSessionListIntent()

        XCTAssertEqual(acao, .reload)
        XCTAssertNil(nav.intent)
    }

    func testConsumeSessionListIntentConsomeSelectSession() {
        let nav = NavigationState()
        nav.send(.selectSession(index: 3))

        let acao = nav.consumeSessionListIntent()

        XCTAssertEqual(acao, .selectSession(index: 3))
        XCTAssertNil(nav.intent)
    }

    func testConsumeSessionListIntentNaoConsomeIntentDeOutroDono() {
        let nav = NavigationState()

        // .interrupt é da SessionDetailView (Task 15).
        nav.send(.interrupt)
        XCTAssertNil(nav.consumeSessionListIntent())
        XCTAssertEqual(nav.intent, .interrupt, "intent de outro consumidor não pode ser engolido")

        // .moveCardLeft é do board (Task 14).
        nav.send(.moveCardLeft)
        XCTAssertNil(nav.consumeSessionListIntent())
        XCTAssertEqual(nav.intent, .moveCardLeft, "intent de outro consumidor não pode ser engolido")
    }

    func testConsumeSessionListIntentNaoConsomeIntentNil() {
        let nav = NavigationState()
        XCTAssertNil(nav.intent)

        XCTAssertNil(nav.consumeSessionListIntent())
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
