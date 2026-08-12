import Foundation

/// O que o terminal de uma máquina deve estar fazendo agora.
enum AcaoDoTerminalDaMaquina: Equatable {
    /// Conectado e lendo o socket.
    case trabalhar
    /// Conectado e calado — o shell, o `cd` e o comando rodando sobrevivem.
    case suspender
    /// Fecha o WebSocket; o hub mata o `ssh` junto (sessão efêmera, sem tmux atrás).
    case desconectar
}

/// Decisão pura do ciclo de vida do `ssh` da aba de máquina (12/08/2026 — abas
/// globais). Existe fora da View porque dentro do `ZStack` de abas o
/// `onDisappear` NUNCA roda (decisão #19: aba montada fica montada), então
/// `.onAppear`/`.onDisappear` deixaram de ser suficientes: sem isto, uma aba de
/// máquina que sai de foco continuaria lendo o socket para sempre e uma que
/// dorme pelo teto de 6 nunca devolveria o `ssh` — é o bug do `✕` do iPad
/// repetido.
///
/// Regra escolhida pela Vanessa: foco = trabalhando; viva atrás de outra aba =
/// conectada mas sem ler; dormindo (teto de 6) ou fechada = desconecta. O custo
/// aceito é uma conexão `ssh` por aba de máquina aberta, até o teto.
enum MachineTerminalLifecycle {
    static func acao(paneState: TerminalPaneState, pane: MachinePane,
                     naTela: Bool) -> AcaoDoTerminalDaMaquina {
        // `liberado` vence tudo: é a única transição que devolve recurso.
        if paneState == .liberado { return .desconectar }
        guard pane == .terminal, naTela, paneState == .ativo else { return .suspender }
        return .trabalhar
    }
}
