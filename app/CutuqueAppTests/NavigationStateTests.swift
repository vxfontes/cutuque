import Combine
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

    /// D4 (12/08/2026): o destino inicial (Sessões) volta pra `.doubleColumn`
    /// ao reabrir — antes voltava pra `.all`, porque a orientação padrão
    /// (paisagem) fazia `expandedVisibility` devolver `.all` nas Sessões.
    func testExpandirEhReversivel() {
        let nav = NavigationState()
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// Em Sessões o ⤡ depende da orientação: em pé, "aberto" são DUAS colunas
    /// (sessões | painel), não três. Três colunas na largura de um iPad em
    /// retrato deixariam o terminal com um filete — o oposto do que o ⤡ existe
    /// pra fazer.
    func testExpandirEmSessoesRetratoVoltaParaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .sessions
        let selecao = makeSelection()
        nav.selection = selecao
        // [12/08/2026 — abas globais] Quem decide o colapso é `abaEmFoco`
        // agora, não `selection` — ver `layoutVisibility`.
        nav.abaEmFoco = ChaveDeAba.para(selecao)
        nav.applyLayoutRule(isPortrait: true)   // é ela que grava a orientação
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// Deitado, "aberto" também são duas colunas — D4 (12/08/2026): deixou de
    /// haver diferença por orientação aqui. Era `.all` (três colunas) antes;
    /// virou `.doubleColumn` junto com `expandedVisibility` (ver
    /// `testExpandidoEhSempreDuasColunasNasSessoes`, acima).
    func testExpandirEmSessoesPaisagemTambemVoltaParaDoubleColumn() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: false)
        nav.toggleColumns()                     // .all -> .detailOnly
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
        nav.toggleColumns()
        XCTAssertEqual(nav.columnVisibility, .doubleColumn)
    }

    /// D4 (12/08/2026): girar o iPad não muda mais o alvo do ⤡ nas Sessões —
    /// antes a orientação gravada por `applyLayoutRule` decidia entre
    /// `.doubleColumn` e `.all`; agora `expandedVisibility` é `.doubleColumn`
    /// nas duas, então trocar de orientação não move o alvo.
    func testOrientacaoNaoMudaMaisOAlvoDoExpandirEmSessoes() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.selection = makeSelection()
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
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

    /// D4: a barra lateral unificada é de DUAS colunas sempre — é ela que faz o
    /// app "parecer PC" e é o que devolve largura no 11". Antes disto, retrato
    /// dava `.doubleColumn` e paisagem dava `.all` (três colunas), e a coluna do
    /// meio comia a largura que o terminal precisava.
    ///
    /// Desvio do plano (12/08/2026): `lastIsPortrait` tem setter `private`
    /// (`private(set)`), então este teste não pode escrever nele direto —
    /// usa `applyLayoutRule(isPortrait:)`, que já é como todo o resto deste
    /// arquivo grava a orientação antes de ler `expandedVisibility`.
    func testExpandidoEhSempreDuasColunasNasSessoes() {
        let nav = NavigationState()
        nav.destination = .sessions
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
    }

    /// O Board é a exceção declarada: `contentColumn` (`RootSplitView.swift`)
    /// depende de `columnVisibility == .all` para NÃO desenhar a lista de destinos
    /// duas vezes lado a lado. Mexer nisto sem ler aquele comentário duplica a
    /// sidebar na tela.
    func testBoardSegueComOArranjoDeleProprio() {
        let nav = NavigationState()
        nav.destination = .board
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
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
    //
    // [12/08/2026 — abas globais] O sinal que decide "sessão escolhida"/"host
    // aberto" nesta tabela deixou de ser `selection`/`machineSelection` e
    // passou a ser `abaEmFoco` — ver `NavigationState.layoutVisibility`. A
    // tabela em si (o QUE cada estado produz) não mudou; só COMO ela é lida
    // agora. Os testes abaixo passaram a gravar `nav.abaEmFoco` (além de, em
    // alguns, continuar gravando `selection`/`machineSelection`, que
    // continuam existindo para destacar a linha escolhida na lista — ver
    // `RootSplitView.contentColumn`).

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
        let selecao = makeSelection()
        nav.selection = selecao
        nav.abaEmFoco = ChaveDeAba.para(selecao)
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

    /// [Reescrito em 12/08/2026 — abas globais] Trocar de destino NÃO limpa
    /// mais `selection` (ver o comentário reescrito de
    /// `NavigationState.destination`). Antes disto, sair pro Board e voltar
    /// pras Sessões tinha que cair na LISTA em vez da última sessão aberta, e a
    /// única ferramenta disponível pra isso era zerar `selection` na troca. Com
    /// `abaEmFoco` decidindo o colapso (ver `layoutVisibility`), a lista aparece
    /// de volta sozinha quando não há aba aberta — sem precisar destruir a
    /// seleção da lista.
    func testTrocarDeDestinoNaoLimpaMaisASelecaoDeSessao() {
        let nav = NavigationState()
        nav.selection = makeSelection()

        nav.destination = .board

        XCTAssertNotNil(nav.selection)
    }

    /// Cenário completo do desenho novo: uma sessão pode continuar
    /// "selecionada" na lista (linha destacada, `selection` não-nil) sem que
    /// exista NENHUMA aba escolhida (`abaEmFoco == nil`) — é exatamente o caso
    /// que este teste acrescenta à tabela-verdade do layout. Sessões (seleção
    /// mas sem aba aberta) → Board → Sessões, em retrato, tem que mostrar a
    /// LISTA (`.doubleColumn`), porque quem decide o colapso é `abaEmFoco`,
    /// não `selection`.
    func testSelecaoSemAbaEmFocoMostraAListaMesmoDepoisDeVoltarDoBoard() {
        let nav = NavigationState()
        nav.selection = makeSelection()
        nav.destination = .board

        nav.destination = .sessions
        nav.applyLayoutRule(isPortrait: true)

        XCTAssertNotNil(nav.selection, "a seleção sobrevive à troca de destino agora")
        XCTAssertNil(nav.abaEmFoco, "nenhuma aba foi aberta neste cenário")
        XCTAssertEqual(nav.columnVisibility, .doubleColumn,
                       "sem aba escolhida, retrato mostra a lista — não o painel")
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

    // MARK: - Máquinas (F5, iPad)
    //
    // Mesma tabela das Sessões, com um motivo a mais para colapsar: a largura
    // do painel não é estética, são as COLUNAS que o `stty` do outro lado vai
    // ver. Um terminal na terceira coluna de um iPad em pé quebra a linha do
    // prompt de verdade.

    /// Máquina cadastrada pelo app no modelo novo: `host` e `identity` separados,
    /// `dest` só como o que o hub derivou (`vx@192.0.2.50`). Estes testes são de
    /// navegação — não olham identidade nem tema —, mas os campos vão preenchidos
    /// de propósito: fixture com `nil` em tudo passaria mesmo se a tela de
    /// máquinas parasse de receber identidade do hub.
    private func makeMachine(_ name: String = "vps") -> Machine {
        Machine(name: name, dest: "vx@192.0.2.50", port: 22, source: "app",
                hostFingerprint: "SHA256:abc",
                host: "192.0.2.50", identity: "vx", os: "Darwin 24.5.0", theme: "dracula",
                icon: nil)
    }

    func testMaquinasComHostAbertoEmRetratoColapsaDetailOnly() {
        let nav = NavigationState()
        nav.destination = .machines
        let machine = makeMachine()
        nav.machineSelection = machine
        // [12/08/2026 — abas globais] Quem decide o colapso é `abaEmFoco`
        // agora, não `machineSelection` — ver `layoutVisibility`.
        nav.abaEmFoco = .maquina(machine.name)
        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .detailOnly)
    }

    /// Em paisagem cabem as três: destinos | hosts | terminal.
    func testMaquinasComHostAbertoEmPaisagemFicaAll() {
        let nav = NavigationState()
        nav.destination = .machines
        nav.machineSelection = makeMachine()
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    /// Sem host aberto não há nada a espremer — nem em pé. Diferente das
    /// Sessões, a coluna do meio aqui tem conteúdo próprio (a lista de hosts),
    /// então não existe a troca de coluna que lá justifica `.doubleColumn`.
    func testMaquinasSemHostAbertoFicaAllNasDuasOrientacoes() {
        let nav = NavigationState()
        nav.destination = .machines
        nav.machineSelection = nil

        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.columnVisibility, .all)
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.columnVisibility, .all)
    }

    /// O ⤡ em Máquinas segue as Sessões: "aberto" são duas colunas em
    /// qualquer orientação (D4, 12/08/2026 — antes paisagem devolvia `.all`).
    /// Voltar pras três devolveria o terminal-filete que o botão existe pra
    /// desfazer.
    func testExpandirEmMaquinasSegueAOrientacao() {
        let nav = NavigationState()
        nav.destination = .machines

        nav.applyLayoutRule(isPortrait: true)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
        nav.applyLayoutRule(isPortrait: false)
        XCTAssertEqual(nav.expandedVisibility, .doubleColumn)
    }

    /// [Reescrito em 12/08/2026 — abas globais] Trocar de destino NÃO derruba
    /// mais o host aberto. Antes, sair da coluna destruía o painel — e com ele
    /// o WebSocket, e o hub matava o `ssh` junto — porque o painel MORAVA na
    /// coluna do destino. Hoje o painel mora na ABA (global, em qualquer
    /// destino), e quem manda no `ssh`/no espelho é `OpenTabs.estado(de:)` (ver
    /// `MachineTerminalLifecycle`); `machineSelection` só destaca a linha na
    /// lista de hosts, e limpá-la ao trocar de destino não desconectaria mais
    /// nada — só dessincronizaria a lista da aba que segue aberta.
    func testTrocarDeDestinoNaoDerrubaMaisOHostAberto() {
        let nav = NavigationState()
        nav.destination = .machines
        nav.machineSelection = makeMachine()

        nav.destination = .board

        XCTAssertNotNil(nav.machineSelection)
    }

    /// Tocar no destino já ativo (a `List(selection:)` da sidebar reescreve a
    /// cada toque) não pode derrubar o terminal aberto ao lado.
    func testReatribuirOMesmoDestinoNaoDerrubaOHost() {
        let nav = NavigationState()
        nav.destination = .machines
        nav.machineSelection = makeMachine()

        nav.destination = .machines

        XCTAssertNotNil(nav.machineSelection)
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
        let selecao = makeSelection()
        nav.selection = selecao
        nav.abaEmFoco = ChaveDeAba.para(selecao)

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

    // MARK: - Modo do painel por aba [12/08/2026]
    //
    // Achado crítico da revisão adversarial pós-G6: `paneMode` era um
    // `@Published` ÚNICO compartilhado por todo o app. Com N `SessionDetailPane`
    // montados ao mesmo tempo (um por aba, decisão #19), escrever nele de uma
    // aba vazava pra todas as outras. Estes três testes cobrem a parte pura
    // (sem hosting de View) da correção: o dicionário por chave, o redirect via
    // `abaEmFoco` e a limpeza de abas fechadas.

    /// O bug em miniatura: duas abas guardam modos DIFERENTES, e escrever numa
    /// não pode tocar na outra.
    func testDoisModosDeDuasChavesDiferentesNaoSeAtropelam() {
        let nav = NavigationState()
        let abaAoVivo = ChaveDeAba(tipo: .live, machine: "m1", alvo: "%1")
        let abaDeChat = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")

        nav.definirPaneMode(.terminal, de: abaAoVivo)
        nav.definirPaneMode(.chat, de: abaDeChat)

        XCTAssertEqual(nav.paneMode(de: abaAoVivo), .terminal)
        XCTAssertEqual(nav.paneMode(de: abaDeChat), .chat)

        // Reescrever a de chat pra `.terminal` não pode mexer na ao vivo —
        // era exatamente isto que o `@Published var paneMode` único fazia.
        nav.definirPaneMode(.terminal, de: abaDeChat)
        XCTAssertEqual(nav.paneMode(de: abaAoVivo), .terminal)
        XCTAssertEqual(nav.paneMode(de: abaDeChat), .terminal)
    }

    /// Uma chave nunca visitada devolve `.chat` (o padrão antigo do
    /// `@Published var paneMode = .chat`); `nil` (iPhone, sem aba em foco)
    /// devolve o modo "sem aba", independente do que qualquer aba guarda.
    func testChaveNuncaVisitadaComecaEmChatENilUsaModoSemAba() {
        let nav = NavigationState()
        let aba = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")

        XCTAssertEqual(nav.paneMode(de: aba), .chat)
        XCTAssertEqual(nav.paneMode(de: nil), .chat)

        nav.definirPaneMode(.terminal, de: aba)
        XCTAssertEqual(nav.paneMode(de: aba), .terminal)
        XCTAssertEqual(nav.paneMode(de: nil), .chat, "escrever numa aba não pode mudar o modo sem aba")
    }

    /// `nav.paneMode` (a propriedade de compatibilidade que `CutuqueCommands`
    /// e o ⌘⇧T leem/escrevem sem saber de abas) tem de seguir `abaEmFoco` — é
    /// isso que faz o atalho continuar agindo sobre a aba que a usuária está
    /// olhando, mesmo depois de trocar de aba sem tocar no seletor.
    func testAbaEmFocoRedirecionaOPaneModeDeCompatibilidade() {
        let nav = NavigationState()
        let aba1 = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")
        let aba2 = ChaveDeAba(tipo: .live, machine: "m1", alvo: "%2")

        nav.definirPaneMode(.chat, de: aba1)
        nav.definirPaneMode(.terminal, de: aba2)

        nav.abaEmFoco = aba1
        XCTAssertEqual(nav.paneMode, .chat)

        nav.abaEmFoco = aba2
        XCTAssertEqual(nav.paneMode, .terminal)

        // Escrever em `nav.paneMode` (o que `CutuqueCommands` faz) tem de
        // escrever na aba em foco, não em algum lugar solto.
        nav.paneMode = .info
        XCTAssertEqual(nav.paneMode(de: aba2), .info)
        XCTAssertEqual(nav.paneMode(de: aba1), .chat, "aba1 não pode ser afetada por uma escrita com foco em aba2")
    }

    /// [13/08/2026] A faixa da `ChromeDaAba` desenha `escolha(de:)`, que é um
    /// cache paralelo a `modosPorAba`. Todo escritor de modo que não seja o
    /// Picker da chrome tem de atualizar os dois, senão o seletor MENTE sobre o
    /// conteúdo. O caminho testado aqui é o ✕ de fechar o terminal, que grava
    /// `.info` direto (`SessionDetailPane.closeTerminalButton`).
    func testDefinirPaneModeSincronizaAEscolhaDaChrome() {
        let nav = NavigationState()
        let aba = ChaveDeAba(tipo: .live, machine: "macmini", alvo: "%1")

        nav.definirSegmentos([SegmentoDeChrome(id: PaneMode.terminal.rawValue, titulo: "Terminal", simbolo: "terminal"),
                              SegmentoDeChrome(id: PaneMode.info.rawValue, titulo: "Info", simbolo: "info.circle")],
                             de: aba)
        nav.escolher(PaneMode.terminal.rawValue, de: aba)

        nav.definirPaneMode(.info, de: aba)   // o ✕, sem passar pela chrome
        XCTAssertEqual(nav.escolha(de: aba), PaneMode.info.rawValue,
                       "seletor da chrome ficaria em Terminal com a Info na tela")
    }

    /// Mesmo defeito pelo outro escritor: o ⌘⇧T do menu, que só conhece a
    /// propriedade de compatibilidade `nav.paneMode`.
    func testAtalhoDeCompatibilidadeSincronizaAEscolhaDaChrome() {
        let nav = NavigationState()
        let aba = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")
        nav.abaEmFoco = aba
        nav.definirPaneMode(.chat, de: aba)
        XCTAssertEqual(nav.escolha(de: aba), PaneMode.chat.rawValue)

        nav.paneMode = .terminal              // ⌘⇧T
        XCTAssertEqual(nav.escolha(de: aba), PaneMode.terminal.rawValue)
    }

    /// O guarda de igualdade de `definirPaneMode` não é enfeite: pela decisão
    /// #19 os N painéis ficam montados, então cada publicação recompõe todos.
    func testDefinirPaneModeComValorIgualNaoPublica() {
        let nav = NavigationState()
        let aba = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")
        nav.definirPaneMode(.terminal, de: aba)

        var publicacoes = 0
        let assinatura = nav.objectWillChange.sink { _ in publicacoes += 1 }
        defer { assinatura.cancel() }

        nav.definirPaneMode(.terminal, de: aba)
        XCTAssertEqual(publicacoes, 0)

        nav.definirPaneMode(.info, de: aba)
        XCTAssertGreaterThan(publicacoes, 0, "mudança de verdade tem de publicar")
    }

    /// `descartarModos` é a limpeza que impede `modosPorAba` de crescer pra
    /// sempre: tira o que fechou, preserva o que ficou.
    func testDescartarModosTiraOQueFechouEMantemOQueFicou() {
        let nav = NavigationState()
        let ficou = ChaveDeAba(tipo: .chat, machine: "m1", alvo: "sessao-1")
        let fechou = ChaveDeAba(tipo: .live, machine: "m1", alvo: "%2")

        nav.definirPaneMode(.terminal, de: ficou)
        nav.definirPaneMode(.info, de: fechou)

        nav.descartarModos(mantendo: Set([ficou]))

        XCTAssertEqual(nav.paneMode(de: ficou), .terminal, "a que ficou guarda o valor de antes")
        XCTAssertEqual(nav.paneMode(de: fechou), .chat, "a que fechou volta ao padrão — não existe mais valor guardado")
    }
}
