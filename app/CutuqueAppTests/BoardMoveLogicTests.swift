import XCTest
@testable import CutuqueApp

final class BoardMoveLogicTests: XCTestCase {

    /// `BoardTask` só tem init de decoder — monta um a partir de JSON.
    private func task(id: String = "abc", column: String = "a_fazer",
                      encalhada: Bool = false, archived: Bool = false) -> BoardTask {
        let json = """
        {"id":"\(id)","title":"t","column":"\(column)","group":"g","session":"s",
         "encalhada":\(encalhada),"archived":\(archived)}
        """
        return try! JSONDecoder().decode(BoardTask.self, from: Data(json.utf8))
    }

    // MARK: plano

    func testCardArquivadoNaoSeMove() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .column(.feito)))
        XCTAssertNil(BoardMoveLogic.plan(for: task(archived: true), target: .encalhadas))
    }

    func testSoltarNaPropriaColunaNaoFazNada() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(column: "feito"), target: .column(.feito)))
    }

    func testMoverParaOutraColunaEhUmaChamadaSo() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer"), target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testSairDeEncalhadasEhUmaChamadaSo() {
        // O hub limpa a flag sozinho no move (postgres.go:281).
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.emProgresso)),
                       .move(.emProgresso))
    }

    func testEncalhadaVoltandoParaAFazerAindaEhUmMove() {
        // Mesma coluna, mas precisa limpar a flag — não pode virar no-op.
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "a_fazer", encalhada: true),
                                           target: .column(.aFazer)),
                       .move(.aFazer))
    }

    func testMarcarComoEncalhada() {
        XCTAssertEqual(BoardMoveLogic.plan(for: task(column: "em_progresso"), target: .encalhadas),
                       .markEncalhada)
    }

    func testJaEncalhadaNaoRemarca() {
        XCTAssertNil(BoardMoveLogic.plan(for: task(encalhada: true), target: .encalhadas))
    }

    // MARK: aplicação otimista

    func testAplicarMoveTrocaAColunaELimpaAFlag() {
        let antes = [task(id: "a", column: "a_fazer", encalhada: true)]
        let depois = BoardMoveLogic.apply(.move(.feito), to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "feito")
        XCTAssertEqual(depois[0].isEncalhada, false)
    }

    func testAplicarEncalhadaForcaAFazer() {
        let antes = [task(id: "a", column: "em_revisao")]
        let depois = BoardMoveLogic.apply(.markEncalhada, to: antes, id: "a")
        XCTAssertEqual(depois[0].column, "a_fazer")
        XCTAssertEqual(depois[0].isEncalhada, true)
    }

    func testAplicarNumIdInexistenteNaoMexeEmNada() {
        let antes = [task(id: "a")]
        XCTAssertEqual(BoardMoveLogic.apply(.move(.feito), to: antes, id: "zzz"), antes)
    }

    // MARK: teclado

    func testColunaAdjacente() {
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: 1), .emProgresso)
        XCTAssertEqual(BoardMoveLogic.adjacentColumn(from: .emProgresso, offset: -1), .aFazer)
    }

    func testColunaAdjacenteNaoDaVoltaNoBoard() {
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .aFazer, offset: -1))
        XCTAssertNil(BoardMoveLogic.adjacentColumn(from: .concluido, offset: 1))
    }

    // MARK: largura de coluna

    func testNoIPhoneAColunaContinuaPaginando() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 393, columns: 5, isRegular: false),
                       393 * 0.86, accuracy: 0.01)
    }

    func testNoIPadAsColunasDividemALargura() {
        // 1366 - 7 gutters de 12 = 1282 / 6 = 213,7 → cai no piso de 260.
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 6, isRegular: true), 260)
    }

    func testColunaLargaQuandoSobraEspaco() {
        // 1366 - 4 gutters = 1318 / 3 = 439,3
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 3, isRegular: true),
                       439.33, accuracy: 0.1)
    }

    func testZeroColunasNaoDivideProZero() {
        XCTAssertEqual(BoardLayout.columnWidth(available: 1366, columns: 0, isRegular: true),
                       1366 * 0.86, accuracy: 0.01)
    }

    // MARK: idiom (Task 13, correção dos achados Important 1 e 2 da revisão)
    //
    // `horizontalSizeClass == .regular` NÃO é "iPad": iPhone Plus/Pro Max em
    // paisagem também reporta `.regular`. `BoardView` (raiz do iPhone dentro
    // do `RootTabView`) e a busca duplicada da coluna de detalhe (que
    // sobrescrevia em silêncio a busca de `BoardFilterList` no iPad) dependem
    // desta MESMA decisão — travando-a aqui, pura, sem hospedar view.

    func testIPhoneNuncaEhPadNenhumSizeClass() {
        // O idiom do iPhone é fixo (.phone) mesmo quando o size class medido é
        // .regular (Plus/Pro Max em paisagem) — é exatamente o caso que
        // regredia antes desta correção.
        XCTAssertFalse(BoardLayout.isPad(.phone))
    }

    func testIPadEhPad() {
        XCTAssertTrue(BoardLayout.isPad(.pad))
    }

    // MARK: largura medida (Task 16, achado: Slide Over/Split View no mínimo)
    //
    // `isRegular = isPad` ignorava a largura que o `GeometryReader` já media:
    // num iPad em Slide Over (~320 pt) isso dava colunas de 260 pt sem
    // paginação. `isRegularWidth` responde "estou estreito AGORA?" (muda em
    // runtime) e não pode nunca virar `true` num idiom que não é `.pad`
    // (isso continua sendo obrigação de `isPad`, por idiom).

    func testIPadEmSlideOverVoltaAPaginar() {
        // ~320 pt, idiom .pad: abaixo do limiar de 700, não é "regular".
        XCTAssertFalse(BoardLayout.isRegularWidth(idiom: .pad, measuredWidth: 320))
    }

    func testIPadLargoContinuaDividindoAsColunas() {
        // Split View largo / tela cheia: acima do limiar, comportamento
        // regular preservado (nenhuma regressão no caminho já aceito).
        XCTAssertTrue(BoardLayout.isRegularWidth(idiom: .pad, measuredWidth: 1024))
    }

    func testLimiarDos700PtEhInclusivoParaRegular() {
        XCTAssertTrue(BoardLayout.isRegularWidth(idiom: .pad, measuredWidth: 700))
        XCTAssertFalse(BoardLayout.isRegularWidth(idiom: .pad, measuredWidth: 699))
    }

    func testIPhoneNuncaEhRegularPorLarguraNemEmTelaGrande() {
        // Idiom decide "sou iPad?" — iPhone nunca vira "regular" aqui, por
        // maior que a largura medida seja (Pro Max em paisagem, p.ex.).
        XCTAssertFalse(BoardLayout.isRegularWidth(idiom: .phone, measuredWidth: 1024))
    }

    func testColunaVoltaAPaginarQuandoLarguraMedidaEstreita() {
        // Fim a fim: 320 pt medidos, 6 colunas — mesmo com idiom .pad, a
        // função de paginação (`isRegular=false`) devolve os 86% do iPhone.
        let isRegular = BoardLayout.isRegularWidth(idiom: .pad, measuredWidth: 320)
        XCTAssertEqual(BoardLayout.columnWidth(available: 320, columns: 6, isRegular: isRegular),
                       320 * 0.86, accuracy: 0.01)
    }

    // MARK: FilterBar/busca própria do BoardView (Task 16, rodadas 1 e 2)
    //
    // Três eixos independentes decidem se o `BoardFilterList` (coluna do
    // meio, dono de verdade dos filtros e da busca) está visível ao lado do
    // `BoardView` agora:
    //   1. isPad (idiom, nunca muda em runtime)
    //   2. horizontalSizeClass == .compact (Slide Over, Split View no mínimo
    //      — achado da rodada 1)
    //   3. columnVisibility == .detailOnly (regra dos 700 pt da coluna de
    //      DETALHE, `NavigationState.applyWidthRule` — dispara até em tela
    //      cheia `.regular`, sem Split View nenhum, num iPad de 11" em
    //      retrato normal; achado da rodada 2, mesmo bug reaberto por um
    //      gatilho mais comum que o Slide Over)
    //
    // Faltando qualquer um dos três, o `BoardFilterList` sai de vista e o
    // `BoardView` precisa da própria FilterBar/busca — daí o `||`. Tabela-
    // verdade completa: as 8 combinações, não só as que "interessam".

    func testTabelaVerdadeCompletaDosTresEixos() {
        // (isPad, compact, detailOnly) -> esperado
        let casos: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, true),   // iPhone, nada especial
            (false, false, true,  true),   // iPhone, detailOnly (nem se aplica de fato, mas isPad=false já garante true)
            (false, true,  false, true),   // iPhone compacto (retrato comum)
            (false, true,  true,  true),   // iPhone compacto + detailOnly
            (true,  false, false, false),  // iPad largo, todas as colunas visíveis — BoardFilterList AO LADO
            (true,  false, true,  true),   // iPad "regular" mas regra dos 700pt escondeu sidebar+conteúdo (achado rodada 2)
            (true,  true,  false, true),   // iPad em Slide Over/Split View no mínimo (achado rodada 1)
            (true,  true,  true,  true),   // iPad compacto E detailOnly — os dois motivos ao mesmo tempo
        ]
        for (isPad, compact, detailOnly, esperado) in casos {
            XCTAssertEqual(
                BoardLayout.showsOwnFilterAndSearch(isPad: isPad,
                                                     horizontalSizeClassIsCompact: compact,
                                                     columnVisibilityIsDetailOnly: detailOnly),
                esperado,
                "isPad=\(isPad) compact=\(compact) detailOnly=\(detailOnly)"
            )
        }
    }

    // Os 3 testes abaixo (`IPadLargoComTodasAsColunasVisiveis`,
    // `IPadCompacto`, `IPadDetailOnlyEmTelaCheiaRegular`) já estão cobertos,
    // combinação a combinação, por `testTabelaVerdadeCompletaDosTresEixos`
    // acima — são redundantes de propósito (Minor da rodada 3 da revisão):
    // ficam como documentação nomeada dos 3 achados que motivaram cada eixo
    // (rodada 1, rodada 2, e o caso "ao lado" que nunca quebrou), não porque
    // agreguem cobertura nova. Se algum dia virarem manutenção morta, é
    // seguro removê-los sem perder cobertura — a tabela-verdade sozinha já
    // garante as 8 combinações.

    func testIPhoneSempreMostraAPropriaFilterBarEBuscaQualquerCombinacao() {
        // Com isPad=false o resultado tem que ser `true` por curto-circuito,
        // não importa o que os outros dois eixos digam — é a garantia de
        // "iPhone não pode regredir".
        for compact in [false, true] {
            for detailOnly in [false, true] {
                XCTAssertTrue(BoardLayout.showsOwnFilterAndSearch(isPad: false,
                                                                   horizontalSizeClassIsCompact: compact,
                                                                   columnVisibilityIsDetailOnly: detailOnly))
            }
        }
    }

    func testIPadLargoComTodasAsColunasVisiveisEscondeAPropriaFilterBarEBusca() {
        // Único caso `false`: `BoardFilterList` está ao lado — duplicar aqui
        // reproduziria a busca dupla (achado Important 1 da Task 13).
        XCTAssertFalse(BoardLayout.showsOwnFilterAndSearch(isPad: true,
                                                            horizontalSizeClassIsCompact: false,
                                                            columnVisibilityIsDetailOnly: false))
    }

    func testIPadCompactoMostraAPropriaFilterBarEBusca() {
        // Slide Over/Split View no mínimo: `BoardFilterList` colapsou pra
        // trás na pilha — sem isto o board ficaria sem busca nenhuma.
        XCTAssertTrue(BoardLayout.showsOwnFilterAndSearch(isPad: true,
                                                           horizontalSizeClassIsCompact: true,
                                                           columnVisibilityIsDetailOnly: false))
    }

    func testIPadDetailOnlyEmTelaCheiaRegularMostraAPropriaFilterBarEBusca() {
        // O achado da rodada 2: um iPad de 11" em retrato normal (regular,
        // sem Split View nenhum) já colapsa pra `.detailOnly` pela regra dos
        // 700 pt da coluna de detalhe — o board não tem botão pra desfazer
        // isso (só o `expandButton` de sessão chama `toggleColumns()`), e
        // sem esta busca ficaria sem NENHUMA forma de filtrar/buscar.
        XCTAssertTrue(BoardLayout.showsOwnFilterAndSearch(isPad: true,
                                                           horizontalSizeClassIsCompact: false,
                                                           columnVisibilityIsDetailOnly: true))
    }

    // MARK: - `.focusSearch` mutuamente exclusivo (rodada 3 da revisão)

    /// `BoardView` trata `.focusSearch` quando é dono
    /// (`showsOwnFilterAndSearch` true); `BoardFilterList` (que só existe no
    /// iPad, dentro do `RootSplitView`) trata exatamente quando NÃO é —
    /// mesma função pura, um lado negando o outro. Trava aqui, em teste puro,
    /// que os dois nunca concordam: nunca os dois tratam ao mesmo tempo (⌘F
    /// focaria um campo invisível e comeria o intent do dono de verdade),
    /// nunca os dois deixam passar (o intent travaria até outro resetar a
    /// comparação do `Equatable`, já que `.onChange` só dispara na transição).
    ///
    /// O que isto NÃO prova: que `BoardView.swift` e `BoardFilterList.swift`
    /// de fato chamam esta função com esses parâmetros e consomem só no ramo
    /// correto — isso foi conferido por leitura de código (ver relatório),
    /// não por este teste, que só trava o contrato da função pura em si.
    func testExatamenteUmDosDoisConsumidoresTrataFocusSearchNoIPad() {
        for compact in [false, true] {
            for detailOnly in [false, true] {
                let boardViewTrata = BoardLayout.showsOwnFilterAndSearch(
                    isPad: true,
                    horizontalSizeClassIsCompact: compact,
                    columnVisibilityIsDetailOnly: detailOnly)
                let boardFilterListTrata = !boardViewTrata
                XCTAssertTrue(boardViewTrata != boardFilterListTrata,
                              "exatamente um deve tratar: compact=\(compact) detailOnly=\(detailOnly)")
            }
        }
    }
}
