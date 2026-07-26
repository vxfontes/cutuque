import CoreGraphics
import UIKit

/// Onde um card pode ser solto. "Encalhadas" não é coluna do hub — é o
/// predicado `encalhada == true` — mas no board é uma faixa como as outras.
enum BoardDropTarget: Equatable {
    case column(BoardColumn)
    case encalhadas
}

/// O que fazer de fato. Duas ações distintas na API: mover (que já limpa a
/// flag de encalhada no hub) e marcar como encalhada (que já força `a_fazer`).
enum BoardMovePlan: Equatable {
    case move(BoardColumn)
    case markEncalhada
}

enum BoardMoveLogic {

    /// Decide a ação de soltar `task` em `target`. Nil = nada a fazer: card
    /// arquivado (só leitura) ou já está exatamente onde caiu.
    static func plan(for task: BoardTask, target: BoardDropTarget) -> BoardMovePlan? {
        if task.archived == true { return nil }
        switch target {
        case .encalhadas:
            return task.isEncalhada ? nil : .markEncalhada
        case .column(let column):
            // Card encalhado tem `column == "a_fazer"`, mas soltar ele em
            // "A fazer" ainda é um move — é assim que a flag some.
            if task.column == column.rawValue && !task.isEncalhada { return nil }
            return .move(column)
        }
    }

    /// Aplica o plano na lista local, antes da rede responder. É o que impede
    /// o card de voltar visivelmente pra origem enquanto o `load()` não chega.
    static func apply(_ plan: BoardMovePlan, to tasks: [BoardTask], id: String) -> [BoardTask] {
        var out = tasks
        guard let i = out.firstIndex(where: { $0.id == id }) else { return out }
        switch plan {
        case .move(let column):
            out[i].column = column.rawValue
            out[i].encalhada = false
        case .markEncalhada:
            out[i].column = BoardColumn.aFazer.rawValue
            out[i].encalhada = true
        }
        return out
    }

    /// Coluna vizinha, para ⌘← / ⌘→. Nil nas pontas — o board não dá a volta.
    static func adjacentColumn(from column: BoardColumn, offset: Int) -> BoardColumn? {
        guard let i = BoardColumn.allCases.firstIndex(of: column) else { return nil }
        let target = i + offset
        guard BoardColumn.allCases.indices.contains(target) else { return nil }
        return BoardColumn.allCases[target]
    }
}

enum BoardLayout {
    /// Abaixo disto o título do card quebra em três linhas e o kanban vira
    /// ilegível — melhor deixar rolar na horizontal.
    static let minColumnWidth: CGFloat = 260
    static let spacing: CGFloat = 12

    /// No iPhone (compacto) a coluna ocupa ~86% e o board pagina no swipe, como
    /// hoje. No iPad divide a largura entre as colunas visíveis, com piso.
    static func columnWidth(available: CGFloat, columns: Int, isRegular: Bool) -> CGFloat {
        guard isRegular, columns > 0 else { return available * 0.86 }
        let gutters = spacing * CGFloat(columns + 1)
        return max(minColumnWidth, (available - gutters) / CGFloat(columns))
    }

    /// Verdadeiro só no iPad. `horizontalSizeClass == .regular` NÃO serve pra
    /// discriminar isto — iPhone Plus/Pro Max em paisagem também reporta
    /// `.regular`, e usar sizeClass aqui fazia esses aparelhos perderem a
    /// FilterBar, a busca cheia de tela e a paginação por swipe (achado
    /// Important 2 da revisão da Task 13: o `BoardView` dentro do
    /// `RootTabView`, raiz do iPhone, regredia). O mesmo idiom que escolhe a
    /// raiz do app em `CutuqueApp.swift` decide aqui — nunca muda em runtime,
    /// então rotação/Slide Over não trocam o layout no meio do caminho.
    ///
    /// Isto responde "sou iPad?" — decide ESTRUTURA (existe coluna de
    /// filtros, a busca mora nela). NÃO decide layout/paginação: para "estou
    /// estreito AGORA?" (que muda em runtime) ver `isRegularWidth` e
    /// `showsOwnFilterAndSearch` abaixo.
    static func isPad(_ idiom: UIUserInterfaceIdiom) -> Bool { idiom == .pad }

    /// Verdadeiro só quando o idiom é iPad E a largura MEDIDA já comporta
    /// colunas lado a lado — regra dos 700 pt (mesmo limiar de
    /// `PadLayout.expandThreshold`, mesmo espírito). Em Slide Over ou Split
    /// View no mínimo (~320 pt) o idiom continua `.pad`, mas a largura
    /// medida cai abaixo do limiar: as colunas voltam a paginar como no
    /// iPhone (achado da Task 16 — `isRegular = isPad` ignorava a largura que
    /// o próprio `GeometryReader` já media, dando colunas de 260 pt num
    /// viewport de 320 pt, sem paginação). Ao contrário de `isPad(_:)`, isto
    /// muda em runtime (rotação, arraste do divisor): é a resposta a "estou
    /// estreito agora?", não a "sou iPad?".
    static func isRegularWidth(idiom: UIUserInterfaceIdiom, measuredWidth: CGFloat) -> Bool {
        isPad(idiom) && measuredWidth >= PadLayout.expandThreshold
    }

    /// A pergunta certa não é "estou compacto?" — é "o `BoardFilterList`
    /// (coluna do meio, dona de verdade dos filtros e da busca) está visível
    /// ao lado do `BoardView` agora?". Três eixos, independentes, e faltando
    /// QUALQUER um deles o `BoardFilterList` sai de vista:
    ///
    /// 1. idiom `.pad` — só existe coluna de filtros no iPad (estrutura,
    ///    nunca muda em runtime).
    /// 2. `horizontalSizeClass != .compact` — a `NavigationSplitView` não
    ///    colapsou numa pilha de coluna única (Slide Over, Split View no
    ///    mínimo). Achado da rodada 1 da revisão da Task 16.
    /// 3. `columnVisibility != .detailOnly` — a regra dos 700 pt
    ///    (`NavigationState.applyWidthRule`, Task 7) não escondeu
    ///    sidebar+conteúdo. Ela colapsa sempre que a coluna de DETALHE mede
    ///    menos de 700 pt — e isso acontece até em tela cheia `.regular`,
    ///    sem Split View nenhum: um iPad de 11" em retrato normal, três
    ///    colunas, tem só ~554 pt de coluna de detalhe (ver
    ///    `TerminalGeometryTests.swift`). Achado da rodada 2 da revisão: o
    ///    board reabre o MESMO bug por este terceiro eixo, num gatilho mais
    ///    comum que o Slide Over que motivou a task — e sem saída, porque só
    ///    o `expandButton` de sessão chama `toggleColumns()`, o board não
    ///    tem botão equivalente.
    ///
    /// Faltando qualquer um dos três, o `BoardView` precisa da SUA PRÓPRIA
    /// barra de filtros e busca, como sempre foi no iPhone — senão o board
    /// fica sem NENHUMA forma de filtrar ou buscar. No iPad com os três
    /// eixos a favor (largo, colunas todas visíveis) manter as duas buscas
    /// vivas ao mesmo tempo reproduziria a busca dupla escrevendo em
    /// `searchResults` em silêncio (achado Important 1 da revisão da Task 13).
    static func showsOwnFilterAndSearch(isPad: Bool,
                                         horizontalSizeClassIsCompact: Bool,
                                         columnVisibilityIsDetailOnly: Bool) -> Bool {
        !isPad || horizontalSizeClassIsCompact || columnVisibilityIsDetailOnly
    }
}
