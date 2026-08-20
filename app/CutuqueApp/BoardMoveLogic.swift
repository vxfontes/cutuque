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

    // MARK: - Mover a coluna inteira ("mover tudo")

    /// `task` aparece na faixa `faixa`? É a MESMA regra que o hub aplica no
    /// `POST /board/columns/{coluna}/move-all` (`naFaixa`, em
    /// `hub/internal/server/board_http.go`) e que o dashboard aplica no
    /// `naFaixa` do `dashboard.html`. As três cópias existem porque cada lado
    /// precisa dela para renderizar; se mudar aqui, mude nos outros dois.
    ///
    /// O detalhe que não é óbvio: card encalhado tem `column == "a_fazer"`,
    /// mas a coluna "A fazer" não o mostra — ele mora na faixa Encalhadas.
    /// Mover "A fazer" não pode levá-lo junto.
    static func naFaixa(_ task: BoardTask, _ faixa: BoardDropTarget) -> Bool {
        switch faixa {
        case .encalhadas:
            return task.isEncalhada
        case .column(let column):
            return task.column == column.rawValue && !(task.isEncalhada && column == .aFazer)
        }
    }

    /// Para onde a faixa pode despejar os cards. Encalhadas é ORIGEM, nunca
    /// destino (decisão da Vanessa): "encalhado" é consequência de virar a
    /// semana sem começar, não um lugar onde se põe card à mão.
    static func destinos(from faixa: BoardDropTarget) -> [BoardColumn] {
        switch faixa {
        case .encalhadas:
            return BoardColumn.allCases
        case .column(let origem):
            return BoardColumn.allCases.filter { $0 != origem }
        }
    }

    /// O segmento de URL que o hub espera em `/board/columns/{isto}/move-all`.
    static func caminho(_ faixa: BoardDropTarget) -> String {
        switch faixa {
        case .encalhadas:        return "encalhadas"
        case .column(let coluna): return coluna.rawValue
        }
    }

    /// Como a faixa se chama na tela.
    static func rotulo(_ faixa: BoardDropTarget) -> String {
        switch faixa {
        case .encalhadas:        return "Encalhadas"
        case .column(let coluna): return coluna.label
        }
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
    /// busca cheia de tela e a paginação por swipe (achado Important 2 da
    /// revisão da Task 13: o `BoardView` dentro do `RootTabView`, raiz do
    /// iPhone, regredia). O mesmo idiom que escolhe a raiz do app em
    /// `CutuqueApp.swift` decide aqui — nunca muda em runtime, então
    /// rotação/Slide Over não trocam o layout no meio do caminho.
    ///
    /// Isto responde "sou iPad?". NÃO decide layout/paginação: para "estou
    /// estreito AGORA?" (que muda em runtime) ver `isRegularWidth` abaixo.
    /// Filtros e busca não dependem mais deste predicado — a `BoardView` é a
    /// única dona, em qualquer idiom, desde que a coluna de filtros do meio
    /// (`BoardFilterList`) foi removida ("filtros sempre em cima", decisão da
    /// usuária na correção de layout pós-Task 16).
    static func isPad(_ idiom: UIUserInterfaceIdiom) -> Bool { idiom == .pad }

    /// Abaixo disto o kanban não comporta colunas lado a lado (elas ficariam
    /// com ~110 pt, com título de card quebrando em três linhas) e volta a
    /// paginar no swipe, como no iPhone.
    ///
    /// Este número já foi compartilhado com a antiga "regra dos 700 pt" da
    /// split view, que decidia o colapso das colunas por largura medida. Essa
    /// regra virou orientação e o limiar migrou pra cá: hoje ele responde uma
    /// pergunta só — "cabe kanban em colunas nesta largura?" — e pode mudar
    /// sem afetar mais nada.
    static let columnPagingThreshold: CGFloat = 700

    /// Verdadeiro só quando o idiom é iPad E a largura MEDIDA já comporta
    /// colunas lado a lado. Em Slide Over ou Split
    /// View no mínimo (~320 pt) o idiom continua `.pad`, mas a largura
    /// medida cai abaixo do limiar: as colunas voltam a paginar como no
    /// iPhone (achado da Task 16 — `isRegular = isPad` ignorava a largura que
    /// o próprio `GeometryReader` já media, dando colunas de 260 pt num
    /// viewport de 320 pt, sem paginação). Ao contrário de `isPad(_:)`, isto
    /// muda em runtime (rotação, arraste do divisor): é a resposta a "estou
    /// estreito agora?", não a "sou iPad?".
    static func isRegularWidth(idiom: UIUserInterfaceIdiom, measuredWidth: CGFloat) -> Bool {
        isPad(idiom) && measuredWidth >= columnPagingThreshold
    }
}

/// Os textos do popup de "mover tudo" — separados da view pelo mesmo motivo do
/// `CloseWeekPrompt`: contagem, singular/plural e o aviso de filtro são regra,
/// não desenho, e dá para testar sem tela.
enum MoveAllPrompt {

    static func title(_ faixa: BoardDropTarget) -> String {
        "Mover tudo de \(BoardMoveLogic.rotulo(faixa))?"
    }

    /// `total` é o que o hub vai mover (a coluna inteira); `visivel` é o que a
    /// tela mostra com os filtros da barra aplicados. Quando divergem, avisa —
    /// o endpoint não conhece filtro, e a Vanessa pediu confirmação com a
    /// contagem justamente para não mover o que ela não está vendo sem saber.
    static func message(total: Int, visivel: Int,
                        from faixa: BoardDropTarget, to destino: BoardColumn) -> String {
        let verbo = total == 1 ? "vai" : "vão"
        var texto = "\(cards(total)) de \(BoardMoveLogic.rotulo(faixa)) \(verbo) para \(destino.label)."
        let escondidos = max(0, total - visivel)
        if escondidos > 0 {
            texto += " Os filtros escondem \(escondidos), mas o hub move a coluna inteira."
        }
        return texto
    }

    static func cards(_ n: Int) -> String { "\(n) card\(n == 1 ? "" : "s")" }
}
