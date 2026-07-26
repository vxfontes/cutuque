import CoreGraphics

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
}
