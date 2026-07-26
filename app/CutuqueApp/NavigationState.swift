import SwiftUI

/// Destinos da sidebar do iPad que ocupam as colunas de conteúdo e detalhe.
/// Histórico, Hub e Ajustes também moram na sidebar, mas abrem em sheet — não
/// são destinos de coluna (ver `DestinationSidebar`).
enum PadDestination: String, CaseIterable, Identifiable, Hashable {
    case sessions, board, archive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessões"
        case .board:    return "Board"
        case .archive:  return "Arquivo"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .board:    return "rectangle.split.3x1"
        case .archive:  return "archivebox"
        }
    }
}

/// O que o painel de detalhe mostra quando o destino é Sessões. Uma sessão do
/// registry abre chat (+ terminal, se tiver pane); uma entrada ao vivo do tmux
/// só tem terminal.
enum DetailSelection: Hashable {
    case session(Session)
    case live(LiveEntry)
}

enum PaneMode: String, CaseIterable {
    case chat, terminal
}

/// Ações disparadas por atalho de teclado que precisam do contexto de uma view
/// (a lista de sessões, o board) para acontecer. Quem consome zera com
/// `consume()`.
enum AppIntent: Equatable {
    case reload
    case newSession
    case focusSearch
    case interrupt
    case selectSession(index: Int)
    case moveCardLeft
    case moveCardRight
}

/// Estado de navegação da versão iPad. Vive no `CutuqueApp` (para os atalhos
/// da cena `Commands` alcançarem) e desce por `environmentObject`.
///
/// Ele guarda **estado**, nunca estrutura: girar o iPad muda `columnVisibility`
/// e mais nada. É isso que impede a `NavigationSplitView` de ser remontada e,
/// com ela, o espelho do tmux de ser derrubado.
@MainActor
final class NavigationState: ObservableObject {
    @Published var destination: PadDestination = .sessions
    @Published var selection: DetailSelection?
    @Published var paneMode: PaneMode = .chat
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var archiveSelection: BoardTask?
    /// Card aberto no inspector do board (também alimentado pela busca).
    @Published var boardSelection: BoardTask?
    @Published var intent: AppIntent?

    /// O que está no detalhe agora disputa largura? Board sempre; sessão só
    /// quando está mostrando o terminal.
    var wantsWidth: Bool {
        destination == .board || (destination == .sessions && paneMode == .terminal)
    }

    func toggleColumns() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    /// Aplica a regra dos 700 pt. Chamada UMA vez por entrada em destino/painel
    /// (ver `RootSplitView`): depois disso a escolha do ⤡ é da usuária e vale
    /// até ela trocar de destino.
    func applyWidthRule(detailWidth: CGFloat) {
        columnVisibility = (wantsWidth && PadLayout.startsExpanded(detailWidth: detailWidth))
            ? .detailOnly
            : .all
    }

    func send(_ intent: AppIntent) { self.intent = intent }
    func consume() { intent = nil }
}
