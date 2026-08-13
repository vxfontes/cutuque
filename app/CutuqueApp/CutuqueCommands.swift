import SwiftUI

/// Atalhos ⌘ do iPad. Além de funcionarem com teclado físico, alimentam
/// sozinhos o painel que o iPadOS mostra ao segurar ⌘ — não precisa de código
/// extra pra isso.
///
/// Os que dependem do contexto de uma view (recarregar o board, focar a busca,
/// abrir a n-ésima sessão) viram `AppIntent` e são consumidos por quem tem o
/// contexto; os que são só estado mexem no `NavigationState` direto.
struct CutuqueCommands: Commands {
    @ObservedObject var nav: NavigationState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nova tarefa") { nav.send(.newSession) }
                .keyboardShortcut("n")
        }

        CommandMenu("Cutuque") {
            Button("Recarregar") { nav.send(.reload) }
                .keyboardShortcut("r")
            Button("Buscar no board") {
                nav.destination = .board
                nav.send(.focusSearch)
            }
            .keyboardShortcut("f")

            Divider()

            // "Próximo painel" e não mais "Chat / Terminal": o que ele alterna
            // depende da aba (Terminal↔Info ao vivo, Terminal↔Arquivos na
            // máquina), então nomear dois painéis fixos mentiria no menu. Quem
            // faz a conta é `NavigationState.alternarSegmento` — ver lá por que
            // não pode ser um `paneMode` escrito na mão.
            Button("Próximo painel") { nav.alternarSegmento() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(nav.columnVisibility == .detailOnly ? "Recolher painel" : "Expandir painel") {
                // Mesma curva do `expandButton` de `SessionDetailPane` — as
                // duas superfícies do mesmo atalho ⌘⌃F precisam produzir a
                // MESMA animação, senão o colapso ora anima, ora salta
                // dependendo de qual handler o sistema resolver.
                withAnimation(.columnToggle) { nav.toggleColumns() }
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Parar o agente") { nav.send(.interrupt) }
                .keyboardShortcut(".")

            Divider()

            Button("Board") { nav.destination = .board }
                .keyboardShortcut(digitShortcut(0))
            ForEach(1...9, id: \.self) { n in
                Button("Sessão \(n)") {
                    nav.destination = .sessions
                    nav.send(.selectSession(index: n - 1))
                }
                .keyboardShortcut(digitShortcut(n))
            }

            Divider()

            Button("Mover card pra esquerda") { nav.send(.moveCardLeft) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Mover card pra direita") { nav.send(.moveCardRight) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }
}

/// `KeyEquivalent` de um dígito 0…9 — um único ponto de construção pro
/// atalho do Board (0) e da `ForEach` de sessões (1…9), que são o mesmo tipo
/// de coisa (dígito → tecla). `KeyEquivalent` conforma a
/// `ExpressibleByExtendedGraphemeClusterLiteral`, mas isso só se aplica a
/// literais escritos direto no código-fonte; `n` é uma variável, então o
/// `Character(String)` explícito continua necessário aqui.
private func digitShortcut(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character("\(n)"))
}
