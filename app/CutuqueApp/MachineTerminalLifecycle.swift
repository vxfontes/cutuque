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

    /// Decisão pura de quando o painel Arquivos pode chamar a API do hub
    /// (achado 2 da revisão adversarial da Task 5, 12/08/2026). Antes das abas
    /// globais, `FileBrowserView` tinha um `.task` incondicional: só existia UM
    /// `MachineDetailView` montado por vez, então uma chamada REST extra na
    /// troca de painel era barata. Com a barra de abas global (decisão #19: aba
    /// criada fica montada para sempre, `.onAppear` dispara uma vez só) isso
    /// virou um vazamento: N abas de máquina restauradas do disco no boot = N
    /// `listFiles` simultâneos, um por aba, mesmo para abas que a usuária nunca
    /// olhou — escapando do teto de 6 abas vivas, que existe exatamente para
    /// limitar esse tipo de custo. O `isActive` que já existe em
    /// `FileBrowserView` não resolve: seu comentário está certo ao dizer que ele
    /// só governa a toolbar (`.opacity` não alcança a `.toolbar`, que compõe
    /// todas as views montadas) — ele nunca foi pensado para portão de rede.
    /// Verdadeiro só quando a aba está em foco (`naTela`), o painel selecionado
    /// é Arquivos e a aba está `.ativo` (não suspensa atrás de outra, não
    /// liberada pelo teto de 6).
    static func carregaArquivos(paneState: TerminalPaneState, pane: MachinePane,
                                naTela: Bool) -> Bool {
        pane == .files && naTela && paneState == .ativo
    }
}
