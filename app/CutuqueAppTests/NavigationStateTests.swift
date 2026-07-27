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

    func testExpandirEhReversivel() {
        let nav = NavigationState()
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    /// Em Sessões o ⤡ depende da orientação: em pé, "aberto" são DUAS colunas
    /// (sessões | painel), não três. Três colunas na largura de um iPad em
    /// retrato deixariam o terminal com um filete — o oposto do que o ⤡ existe
    /// pra fazer.
    func testExpandirEmSessoesRetratoVoltaParaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: true)   // é ela que grava a orientação
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// Deitado, "aberto" continua sendo as três colunas do desenho.
    func testExpandirEmSessoesPaisagemVoltaParaAll() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: false)
        nav.toggleColumns()                     // .all -> .detailOnly
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    /// Girar com o painel em tela cheia não reabre nada — mas troca o que o
    /// ⤡ vai abrir depois. Sem isto, girar pra paisagem e tocar no ⤡ ainda
    /// devolveria as duas colunas do retrato.
    func testOrientacaoGravadaMudaOAlvoDoExpandir() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.expandedVisibility, .all)
    }

    /// No Board o ⤡ volta pra `.doubleColumn`, não pra `.all` — ali a lista
    /// de destinos vive na coluna do meio, e `.all` mostraria a sidebar ao
    /// lado dela: a mesma lista duas vezes.
    func testExpandirNoBoardVoltaParaDoubleColumnNaoAll() {
        let nav = NavigationState()
        nav.destination = .board
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    // MARK: - applyLayoutRule (Tarefa B: orientação decide o layout, no lugar
    // da largura medida — regra dos 700 pt aposentada)
    //
    // Tabela-verdade pedida pela usuária, hardcoded aqui (nunca derivada de
    // `applyLayoutRule`/`layoutVisibility` — comparar f(x) com uma reescrita
    // de f é tautologia, achado já registrado neste projeto):
    //
    // | Destino / estado                   | Retrato       | Paisagem      |
    // |------------------------------------|---------------|---------------|
    // | Sessões, nenhuma sessão escolhida  | .doubleColumn | .all          |
    // | Sessões, uma sessão escolhida      | .detailOnly   | .all          |
    // | Board                              | .doubleColumn | .doubleColumn |
    //
    // O Board é `.doubleColumn` porque o desenho dele é de DUAS colunas —
    // "sessoes e board | board em si". Cuidado com o que `.doubleColumn`
    // significa numa split view de TRÊS colunas: ele esconde a SIDEBAR e
    // deixa coluna do meio + detalhe (verificado na tela do simulador — a
    // leitura intuitiva, "esconde a do meio", é falsa). Quem faz o desenho
    // acontecer é `RootSplitView.contentColumn`, que no Board põe a lista de
    // destinos na coluna do meio. Este arquivo testa só a metade
    // `columnVisibility` do arranjo; a outra metade é estrutura de View.
    //
    // Sessões em retrato sem seleção mudou de `.all` pra `.doubleColumn` a
    // pedido da usuária ("na vertical acho que pode deixar 2 colunas sem
    // selecionar terminais mesmo"). Vale a mesma ressalva do Board, e ela é
    // mais traiçoeira aqui: o que fica visível são as colunas do meio e de
    // detalhe, e é `RootSplitView` que nesse estado põe a lista de DESTINOS no
    // meio e a lista de SESSÕES no detalhe. Ler `.doubleColumn` como "sidebar +
    // lista" inverte o arranjo.
    //
    // `paneMode` não participa: trocar Chat↔Terminal não pode mexer em
    // `columnVisibility` (decisão explícita da usuária).

    private func makeSelection() -> DetailSelection {
        .live(LiveEntry(machine: "mac1", session: DiscoveredSession(id: "s1", cwd: "/tmp", title: "t")))
    }

    /// Duas colunas em pé: "sessoes e board | sessoes listadas". Note que a
    /// lista de sessões aqui é o DETALHE — ver a ressalva na tabela acima.
    func testSessoesSemSelecaoRetratoFicaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = nil
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    func testSessoesSemSelecaoPaisagemFicaAll() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = nil
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    func testSessoesComSelecaoRetratoColapsaDetailOnly() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
    }

    func testSessoesComSelecaoPaisagemFicaAllComTresColunas() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    /// Sair pra outro destino solta a sessão escolhida — voltar pras Sessões
    /// tem que cair na LISTA, não na última sessão aberta. Sem isto, em
    /// retrato, `layoutVisibility` colapsa pra `.detailOnly` na volta e a
    /// lista some (reportado no teste da Vanessa no iPad).
    func testTrocarDeDestinoLimpaASelecaoDeSessao() {
        let nav = NavigationState()
        nav.selection = makeSelection()

        nav.destination = .board

        XCTAssertNil(nav.selection)
    }

    /// E a volta pras Sessões continua sem seleção: é o cenário completo do
    /// bug — Sessões (com uma aberta) → Board → Sessões deve mostrar a lista.
    func testVoltarPrasSessoesDepoisDoBoardMostraALista() {
        let nav = NavigationState()
        nav.selection = makeSelection()
        nav.destination = .board

        nav.destination = .sessions
        nav.applyLayoutRule(isPortrait: true)

        XCTAssertNil(nav.selection)
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// Reatribuir o MESMO destino não é troca de destino e não pode limpar
    /// nada: a `List(selection:)` da barra lateral reescreve o destino a cada
    /// toque, inclusive no item já ativo, e isso não pode fechar a sessão
    /// que está aberta ao lado.
    func testReatribuirOMesmoDestinoNaoLimpaASelecao() {
        let nav = NavigationState()
        nav.selection = makeSelection()

        nav.destination = .sessions

        XCTAssertNotNil(nav.selection)
    }

    /// A seleção do board sobrevive à troca de destino — só `selection`
    /// participa da regra de layout, então só ela precisa cair.
    func testTrocarDeDestinoNaoMexeNaSelecaoDoBoard() {
        let nav = NavigationState()
        nav.boardSelection = BoardTask(
            id: "t1", title: "Card", column: "backlog", group: "g", session: "s"
        )

        nav.destination = .board
        nav.destination = .sessions

        XCTAssertEqual(nav.boardSelection?.id, "t1")
    }

    func testBoardEmRetratoFicaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    func testBoardEmPaisagemTambemFicaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .board
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// `paneMode` saiu da decisão: mesmo destino/seleção/orientação,
    /// trocar Chat↔Terminal não pode mudar o resultado.
    func testPaneModeNaoParticipaMaisDaDecisao() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()

        nav.paneMode = .chat
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)

        nav.paneMode = .terminal
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
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

    // MARK: - IntentEvent (correção do achado Critical da revisão final:
    // `.onChange` mudo em reenvio idêntico)
    //
    // `AppIntent` é `Equatable`, e todo consumidor observa via
    // `.onChange(of: nav.intentEvent)` — não mais `nav.intent` cru. Sem o
    // `seq` do envelope, `send(.interrupt)` seguido de outro `send(.interrupt)`
    // sem consumo no meio produziria `oldValue == newValue` no que o
    // `.onChange` compara, e a segunda invocação do atalho nunca dispararia:
    // o atalho ficaria morto até algum OUTRO intent transitar e resetar por
    // acaso. Estes testes cobrem exatamente essa transição, sem hospedar
    // nenhuma View — `IntentEvent` é tipo puro, como o resto desta suíte.

    func testReenviarOMesmoIntentSemConsumirProduzEventosDiferentes() {
        let nav = NavigationState()
        nav.send(.interrupt)
        let primeiro = nav.intentEvent

        nav.send(.interrupt)
        let segundo = nav.intentEvent

        XCTAssertEqual(primeiro.intent, .interrupt)
        XCTAssertEqual(segundo.intent, .interrupt)
        XCTAssertNotEqual(primeiro, segundo,
                           "reenviar o mesmo AppIntent sem consumo no meio tem que ser uma transição observável")
    }

    func testEventosDeIntentsDiferentesTambemDivergem() {
        let nav = NavigationState()
        nav.send(.reload)
        let primeiro = nav.intentEvent

        nav.send(.newSession)
        let segundo = nav.intentEvent

        XCTAssertNotEqual(primeiro, segundo)
    }

    func testConsumeContinuaZerandoIntentComOEnvelopePresente() {
        let nav = NavigationState()
        nav.send(.reload)
        XCTAssertEqual(nav.intentEvent.intent, .reload)

        nav.consume()

        XCTAssertNil(nav.intent, "consume() continua zerando intent — mesma semântica de sempre")
    }

    /// Cenário exato do relato da revisão: ⌘. é apertado sem sessão
    /// selecionada (nenhum consumidor montado, ninguém chama `consume()`).
    /// Depois, já com o consumidor vivo, a usuária aperta ⌘. de novo — esse
    /// segundo aperto TEM que ser uma transição nova, não pode ficar mudo só
    /// porque o `AppIntent` enviado é idêntico ao anterior.
    func testInterruptReenviadoAposFicarSemConsumidorAindaEhConsumivel() {
        let nav = NavigationState()

        // ⌘. antes de escolher sessão: ninguém consome.
        nav.send(.interrupt)
        XCTAssertEqual(nav.intent, .interrupt)

        // A usuária escolhe uma sessão (SessionDetailView monta agora, mas
        // não usamos `initial: true` — o `.interrupt` pendente não é
        // entregue retroativamente no attach, de propósito). Ela aperta ⌘.
        // de novo, querendo de fato parar o agente:
        let eventoAntes = nav.intentEvent
        nav.send(.interrupt)

        XCTAssertNotEqual(nav.intentEvent, eventoAntes,
                           "o segundo ⌘. tem que ser uma nova transição — não pode ficar morto")

        // E agora o consumidor (SessionDetailView, via consumeIfInterrupt)
        // trata normalmente.
        XCTAssertTrue(nav.consumeIfInterrupt())
        XCTAssertNil(nav.intent)
    }

    /// `consumeIfInterrupt()` e `consumeSessionListIntent()` continuam
    /// decidindo com base em `intent`, não em `intentEvent` — reenviar o
    /// mesmo intent não muda QUEM reconhece o quê, só torna a transição
    /// observável. Repete a disciplina de "só consome quem reconhece" already
    /// coberta acima, agora atravessando dois `send()` seguidos do mesmo
    /// intent sem consumo no meio.
    func testConsumeIfInterruptNaoConsomeIntentDeOutroDonoMesmoAposReenvio() {
        let nav = NavigationState()
        nav.send(.moveCardLeft)
        nav.send(.moveCardLeft)   // reenvio idêntico, ninguém consumiu ainda

        XCTAssertFalse(nav.consumeIfInterrupt())
        XCTAssertEqual(nav.intent, .moveCardLeft, "intent de outro consumidor não pode ser engolido")
    }

    func testConsumeSessionListIntentNaoConsomeIntentDeOutroDonoMesmoAposReenvio() {
        let nav = NavigationState()
        nav.send(.interrupt)
        nav.send(.interrupt)   // reenvio idêntico, ninguém consumiu ainda

        XCTAssertNil(nav.consumeSessionListIntent())
        XCTAssertEqual(nav.intent, .interrupt, "intent de outro consumidor não pode ser engolido")
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
