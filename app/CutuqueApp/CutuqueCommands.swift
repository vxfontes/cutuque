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

            Button("Chat / Terminal") {
                nav.paneMode = nav.paneMode == .chat ? .terminal : .chat
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(nav.columnVisibility == .detailOnly ? "Recolher painel" : "Expandir painel") {
                nav.toggleColumns()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Parar o agente") { nav.send(.interrupt) }
                .keyboardShortcut(".")

            Divider()

            Button("Board") { nav.destination = .board }
                .keyboardShortcut("0")
            ForEach(1...9, id: \.self) { n in
                Button("Sessão \(n)") {
                    nav.destination = .sessions
                    nav.send(.selectSession(index: n - 1))
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }

            Divider()

            Button("Mover card pra esquerda") { nav.send(.moveCardLeft) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Mover card pra direita") { nav.send(.moveCardRight) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }
}
