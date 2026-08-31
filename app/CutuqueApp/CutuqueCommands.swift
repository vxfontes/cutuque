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
    /// As abas entram aqui porque com teclado a barra passa a ser navegável sem
    /// o dedo — e mexer nelas é estado puro, sem contexto de view nenhum, então
    /// não precisa passar por `AppIntent`.
    @ObservedObject var tabs: OpenTabsStore

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

            // Atalhos de navegador para a barra de abas. ⌘⇧] / ⌘⇧[ e ⌘W são os
            // do Safari e do Chrome; reabrir ficou em ⌘⌥T, e NÃO no ⌘⇧T de
            // costume, porque este já era o "Próximo painel" desde a versão do
            // iPad — trocar um atalho que ela já tem no dedo custa mais do que
            // ganhar o padrão do navegador aqui.
            Button("Próxima aba", systemImage: "chevron.right") { tabs.mutar { $0.irPara(passo: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabs.tabs.abas.count < 2)
            Button("Aba anterior", systemImage: "chevron.left") { tabs.mutar { $0.irPara(passo: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabs.tabs.abas.count < 2)
            Button("Fechar aba", systemImage: "xmark") {
                guard let atual = tabs.tabs.selecionada else { return }
                tabs.mutar { $0.fechar(atual) }
            }
            .keyboardShortcut("w")
            .disabled(tabs.tabs.selecionada == nil)
            Button("Reabrir aba fechada", systemImage: "arrow.uturn.backward") {
                tabs.mutar { $0.reabrirUltimaFechada() }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(tabs.tabs.fechadasRecentemente.isEmpty)

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
