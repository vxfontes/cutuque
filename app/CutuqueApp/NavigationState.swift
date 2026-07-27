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

/// Envelope publicado no lugar do `AppIntent?` cru pros consumidores que
/// escutam via `.onChange`: carrega um `seq` monotônico.
///
/// `AppIntent` é `Equatable`, e `.onChange` só invoca a closure quando o
/// valor OBSERVADO muda. Sem o `seq`, reenviar o MESMO intent sem que
/// ninguém tenha consumido o anterior produz `oldValue == newValue` — e o
/// atalho correspondente fica morto pra sempre, até algum OUTRO intent
/// transitar e resetar por acaso (achado Critical da revisão final da
/// `versao-ipad`: ver `NavigationState.send(_:)`). `seq` garante que dois
/// `send()` do mesmo `AppIntent` em sequência sempre produzem um
/// `IntentEvent` diferente, então o `.onChange` sempre dispara.
struct IntentEvent: Equatable {
    let seq: Int
    let intent: AppIntent?
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
    /// O que TODO consumidor observa em `.onChange` — nunca `intent` cru (ver
    /// `IntentEvent`). São os três: `SessionListView`, `SessionDetailView` e
    /// `BoardView`.
    ///
    /// `intent` continua existindo como o **payload** que `consume()` zera e
    /// que `consumeIfInterrupt()` lê; `intentEvent` é o **gatilho**, com um
    /// `seq` que muda a cada envio. A separação existe porque `AppIntent` é
    /// `Equatable` e `.onChange` só dispara na transição: dois envios idênticos
    /// seguidos sem consumo no meio (dois `⌘.`, dois `⌘←`) deixariam o segundo
    /// mudo pra sempre sem o `seq`.
    ///
    /// Houve um período em que `BoardFilterList` observava `intent` cru e as
    /// duas coisas coexistiam como mecanismos paralelos. Esse arquivo foi
    /// removido junto com a coluna de filtros — sobrou um mecanismo só.
    @Published private(set) var intentEvent = IntentEvent(seq: 0, intent: nil)
    private var intentSeq = 0

    /// Como as colunas ficam neste destino, nesta orientação — substitui a
    /// antiga regra dos 700 pt (largura medida). `paneMode` NÃO entra aqui: o
    /// colapso em retrato vale pro painel inteiro, seja chat ou terminal
    /// (decisão explícita da usuária — "Chat continua o padrão, só o layout
    /// muda").
    ///
    /// - Board: `.doubleColumn` nas duas orientações — duas colunas, a lista
    ///   de destinos e o kanban, que é o desenho da usuária ("sessoes e
    ///   board | board em si"). Atenção ao que `.doubleColumn` de fato faz
    ///   numa split view de TRÊS colunas: ele esconde a SIDEBAR e mostra
    ///   coluna do meio + detalhe (verificado no simulador — o palpite
    ///   contrário, "esconde a do meio", está errado). Quem entrega o
    ///   desenho é `RootSplitView.contentColumn`, que no Board põe a lista
    ///   de destinos na coluna do meio; ler este `case` sozinho engana.
    /// - Sessões: `.detailOnly` só em retrato E com uma sessão escolhida — é
    ///   aí que o painel (tela cheia) precisa da largura toda; em paisagem as
    ///   três colunas cabem, e sem seleção não há o que colapsar pra.
    /// - Arquivo: sempre `.all` — fora do escopo desta correção, mantém o
    ///   comportamento de sempre (nunca disputou largura).
    func layoutVisibility(isPortrait: Bool) -> NavigationSplitViewVisibility {
        switch destination {
        case .board:
            return .doubleColumn
        case .sessions:
            return isPortrait && selection != nil ? .detailOnly : .all
        case .archive:
            return .all
        }
    }

    /// O ⤡ (e o ⌘⌃F): alterna entre tela cheia e o estado "aberto" do destino
    /// corrente.
    ///
    /// O estado aberto NÃO é `.all` em todo destino — no Board é
    /// `.doubleColumn`. Ali a lista de destinos vive na coluna do MEIO (ver
    /// `RootSplitView.contentColumn`), então `.all` mostraria a sidebar e a
    /// lista lado a lado: a mesma lista duas vezes, e o board espremido numa
    /// terceira coluna.
    func toggleColumns() {
        if columnVisibility == .detailOnly {
            columnVisibility = destination == .board ? .doubleColumn : .all
        } else {
            columnVisibility = .detailOnly
        }
    }

    /// Aplica a regra de layout: orientação (e, pra Sessões, se há seleção)
    /// decide `columnVisibility` — substitui a antiga regra dos 700 pt.
    /// Chamada UMA vez por entrada em destino/seleção/orientação (ver
    /// `RootSplitView`): depois disso a escolha do ⤡ é da usuária e vale até
    /// a chave mudar de novo. Função pura de estado — não lê geometria por
    /// dentro, pra continuar testável sem hosting de View (ver a
    /// tabela-verdade em `NavigationStateTests`).
    func applyLayoutRule(isPortrait: Bool) {
        columnVisibility = layoutVisibility(isPortrait: isPortrait)
    }

    /// Publica o intent E o envelope (`intentEvent`) com `seq` incrementado —
    /// é isso que faz `send(.interrupt)` seguido de outro `send(.interrupt)`,
    /// sem consumo no meio, ser sempre uma transição observável (ver
    /// `IntentEvent`).
    func send(_ intent: AppIntent) {
        self.intent = intent
        intentSeq += 1
        intentEvent = IntentEvent(seq: intentSeq, intent: intent)
    }

    func consume() { intent = nil }

    /// Zera o intent SE (e só se) for `.interrupt`, e diz se consumiu.
    ///
    /// A lista de sessões e o detalhe do chat vivem ao mesmo tempo em colunas
    /// diferentes da split view do iPad: um consumidor que zerasse o intent
    /// em `default:` engoliria atalhos destinados ao vizinho. Por isso a
    /// disciplina de "só chama `consume()` quando reconhece o caso" vive aqui,
    /// testável direto, e não dentro de um `.onChange` de View.
    @discardableResult
    func consumeIfInterrupt() -> Bool {
        guard intent == .interrupt else { return false }
        consume()
        return true
    }

    /// Zera o intent SE (e só se) for um dos três que a lista de sessões
    /// trata — `.newSession`, `.reload`, `.selectSession` — e devolve a ação
    /// equivalente pronta pra View aplicar. Demais casos (`.interrupt`,
    /// `.moveCardLeft`...) voltam `nil` e o intent continua vivo pro vizinho
    /// (o painel de detalhe, na outra coluna da split view) tratar.
    ///
    /// Mesmo espírito do `consumeIfInterrupt()` acima (Task 15): a decisão
    /// "reconheço ou não" mora aqui, testável direto, sem hospedar
    /// `SessionListView` em teste. Achado da Task 11 (revisão): sem isso, um
    /// refactor que trocasse o `default: return` da View por um `consume()`
    /// passava a suíte inteira e engolia ⌘. e ⌘←/⌘→ em silêncio.
    @discardableResult
    func consumeSessionListIntent() -> SessionListIntentAction? {
        let action: SessionListIntentAction?
        switch intent {
        case .newSession:
            action = .newSession
        case .reload:
            action = .reload
        case .selectSession(let index):
            action = .selectSession(index: index)
        default:
            action = nil
        }
        if action != nil {
            consume()
        }
        return action
    }
}

/// Ação equivalente a um `AppIntent` reconhecido pela lista de sessões — ver
/// `NavigationState.consumeSessionListIntent()`.
enum SessionListIntentAction: Equatable {
    case newSession
    case reload
    case selectSession(index: Int)
}
