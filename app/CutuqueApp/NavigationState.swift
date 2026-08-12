import SwiftUI

/// Destinos da sidebar do iPad que ocupam as colunas de conteúdo e detalhe.
/// Histórico, Hub e Ajustes também moram na sidebar, mas abrem em sheet — não
/// são destinos de coluna (ver `DestinationSidebar`).
enum PadDestination: String, CaseIterable, Identifiable, Hashable {
    /// A ordem é a da sidebar, e é a mesma da barra de abas do iPhone
    /// (`RootTabView`) até onde as duas coincidem — quem alterna entre os dois
    /// aparelhos não deveria reaprender o lugar das coisas.
    case sessions, board, machines, archive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessões"
        case .board:    return "Board"
        case .machines: return "Máquinas"
        case .archive:  return "Arquivo"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .board:    return "rectangle.split.3x1"
        case .machines: return "server.rack"
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

/// Qual painel o detalhe mostra. Nem toda seleção tem os três: uma sessão do
/// registry tem `chat` (e `terminal`, se rodar dentro do tmux); uma entrada ao
/// vivo do tmux tem `info` e `terminal`. Quem concilia é
/// `SessionDetailPaneLogic.entryPaneMode`.
///
/// `info` chegou depois, com o iPad: no iPhone tocar numa sessão ao vivo abre
/// primeiro uma tela de informações (`LiveDetailView`) e o terminal vem de um
/// botão dela. O iPad pulava direto pro terminal — "no ao vivo do tmux nao ta
/// abrindo as informações como temos no iphone". Aqui as informações não são
/// uma tela antes, são um dos painéis do seletor: dá pra ir e voltar sem
/// derrubar o espelho, que é o que também resolve o "botao de fechar o
/// terminal" (ele continua montado e inativo — o tmux do outro lado nem fica
/// sabendo).
enum PaneMode: String, CaseIterable {
    case chat, terminal, info
}

/// Qual painel a aba Máquinas mostra para o host aberto. Mesmo desenho do
/// `PaneMode`: os dois ficam montados e alterna-se a opacidade, então trocar de
/// painel não derruba o terminal (o `ssh` do outro lado morreria junto) nem
/// perde onde a navegação de arquivos estava.
///
/// Fica **por host** (`@AppStorage`, chave por nome): quem usa uma máquina para
/// editar arquivo e outra para rodar comando não quer o mesmo painel nas duas.
enum MachinePane: String, CaseIterable {
    case terminal, files

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files:    return "Arquivos"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "apple.terminal"
        case .files:    return "folder"
        }
    }

    /// Chave do `@AppStorage` que lembra o painel deste host.
    static func storageKey(machine: String) -> String {
        "cutuque.machinePane.\(machine)"
    }
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
    /// Trocar de destino LIMPA a seleção de sessão.
    ///
    /// Sem isto, sair pro Board e voltar pra Sessões caía direto na última
    /// sessão aberta em vez da lista — em retrato a regra de layout colapsa
    /// pra `.detailOnly` quando há seleção, então a lista simplesmente não
    /// aparecia (reportado pela Vanessa testando no iPad).
    ///
    /// `boardSelection`/`archiveSelection` NÃO são limpas: não participam de
    /// `layoutVisibility`, e deixar um card aberto pra quando você voltar é
    /// lembrança útil. `selection` e `machineSelection` são, por dois motivos
    /// que se somam: as duas participam do layout (uma seleção pendurada
    /// esconde a lista em retrato) e as duas guardam conexão viva — sair da
    /// coluna destrói o painel, e voltar reabriria um terminal NOVO com cara
    /// do antigo, que é justamente o que o `PTYSession` evita não
    /// reconectando sozinho.
    @Published var destination: PadDestination = .sessions {
        didSet {
            guard oldValue != destination else { return }
            selection = nil
            machineSelection = nil
        }
    }
    @Published var selection: DetailSelection?
    /// [12/08/2026] Modo do painel, GUARDADO POR ABA. Até a G6 isto era um
    /// `@Published var paneMode: PaneMode` único — inofensivo enquanto só
    /// existia UM `SessionDetailPane` montado por vez (`.id(selection)`
    /// recriava a cada troca de sessão). A G6 passou a montar N painéis ao
    /// mesmo tempo, um por aba, todos vivos e todos lendo/escrevendo o mesmo
    /// `paneMode` — abrir uma aba de chat puro forçava `.chat` GLOBALMENTE, e
    /// voltar pra uma aba ao vivo (sem chat) renderizava os três `if` de
    /// `SessionDetailPane.body` em `false`: painel em branco (achado crítico
    /// da revisão adversarial pós-G6). Ver `paneMode(de:)`/`definirPaneMode`.
    @Published private var modosPorAba: [ChaveDeAba: PaneMode] = [:]
    /// Modo de quem não tem aba em foco: iPhone (não usa `OpenTabs`) e
    /// qualquer leitor que passe `nil` pra `paneMode(de:)`. Existia como o
    /// valor inicial do antigo `@Published var paneMode`; agora é só o caso
    /// sem chave do dicionário acima.
    @Published private var modoSemAba: PaneMode = .chat
    /// A aba que está na frente agora — escrito por `RootSplitView`, a partir
    /// de `OpenTabs.selecionada`, num único `.onChange(of: tabsStore.tabs)`.
    /// É o que faz `paneMode` (a propriedade de compatibilidade, abaixo)
    /// continuar significando "o modo que a usuária está vendo": ⌘⇧T e o
    /// item de menu equivalente em `CutuqueCommands` leem/escrevem `nav.paneMode`
    /// sem saber de abas, e funcionam porque ele aponta pra ESTA aba.
    @Published var abaEmFoco: ChaveDeAba?

    /// O modo guardado para `chave` — `nil` (iPhone, ou nenhuma aba em foco)
    /// devolve `modoSemAba`; uma aba sem valor guardado (nunca visitada, ou
    /// acabou de nascer) devolve `.chat`, o mesmo padrão que o
    /// `@Published var paneMode = .chat` antigo tinha antes de qualquer
    /// escrita.
    ///
    /// Não valida contra a seleção da aba — o valor aqui pode ser
    /// IMPOSSÍVEL pra ela (ex.: `.chat` guardado numa aba ao vivo, que não
    /// tem chat). Quem valida é `SessionDetailPaneLogic.modoValido`, na
    /// hora de renderizar; este método só lê o que está guardado, cru.
    func paneMode(de chave: ChaveDeAba?) -> PaneMode {
        guard let chave else { return modoSemAba }
        return modosPorAba[chave] ?? .chat
    }

    /// Escreve o modo guardado de `chave` (ou de `modoSemAba`, se `nil`).
    /// Cru, sem validar contra a seleção da aba — mesma observação de
    /// `paneMode(de:)`.
    func definirPaneMode(_ modo: PaneMode, de chave: ChaveDeAba?) {
        guard let chave else {
            modoSemAba = modo
            return
        }
        modosPorAba[chave] = modo
    }

    /// Propriedade de COMPATIBILIDADE: o modo da aba em foco (`abaEmFoco`).
    /// É o que mantém `CutuqueCommands` (⌘⇧T e o item de menu) e o iPhone
    /// (sem abas, `abaEmFoco` fica sempre `nil`) compilando e funcionando
    /// sem saber que o modo virou por-aba — os dois só conhecem
    /// `nav.paneMode`, nunca `paneMode(de:)`.
    ///
    /// Não é mais `@Published`: é COMPUTADA sobre `modosPorAba`/`modoSemAba`,
    /// que são os `@Published` de verdade. Consequência real: `$nav.paneMode`
    /// deixou de existir. O único lugar que usava o binding era o `Picker` de
    /// `SessionDetailPane` — ele troca pra um `Binding(get:set:)` manual que
    /// lê o modo já validado (`SessionDetailPaneLogic.modoValido`) e escreve
    /// cru na chave da própria aba (ver `SessionDetailPane.swift`).
    var paneMode: PaneMode {
        get { paneMode(de: abaEmFoco) }
        set { definirPaneMode(newValue, de: abaEmFoco) }
    }

    /// Descarta os modos guardados de abas que não existem mais — sem isto
    /// `modosPorAba` cresceria pra sempre a cada aba fechada. Chamado por
    /// `RootSplitView` no mesmo `.onChange(of: tabsStore.tabs)` que atualiza
    /// `abaEmFoco`, com o conjunto de chaves das abas que ainda existem.
    func descartarModos(mantendo vivas: Set<ChaveDeAba>) {
        modosPorAba = modosPorAba.filter { vivas.contains($0.key) }
    }

    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var archiveSelection: BoardTask?
    /// Host aberto na aba Máquinas. Diferente das outras seleções, esta tem um
    /// `ssh` do outro lado: enquanto ela aponta pra uma máquina, existe um
    /// shell vivo no hub (ver `MachineDetailView`).
    @Published var machineSelection: Machine?
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
    /// - Sessões em PAISAGEM: `.all`, as três colunas do desenho da usuária
    ///   ("sessoes e board | sessoes | terminal").
    /// - Sessões em RETRATO, com uma sessão escolhida: `.detailOnly` — o
    ///   painel ocupa a tela toda.
    /// - Sessões em RETRATO, sem seleção: `.doubleColumn`, duas colunas —
    ///   "sessoes e board | sessoes listadas". Mesma manobra do Board: como
    ///   `.doubleColumn` esconde a SIDEBAR (e não a coluna do meio), quem
    ///   entrega o desenho é `RootSplitView`, que nesse estado põe a lista de
    ///   destinos na coluna do meio e a lista de SESSÕES no detalhe. Ler este
    ///   `case` sozinho engana.
    /// - Arquivo: sempre `.all` — fora do escopo desta correção, mantém o
    ///   comportamento de sempre (nunca disputou largura).
    /// - Máquinas em RETRATO, com host aberto: `.detailOnly`, pela mesma razão
    ///   das Sessões — um terminal na terceira coluna de um iPad em pé vira um
    ///   filete, e aqui a largura não é estética: são as colunas que o `stty`
    ///   do outro lado vai ver.
    /// - Máquinas nos demais casos: `.all`. Sem host aberto não há nada a
    ///   espremer, e a coluna do meio tem conteúdo próprio (a lista de hosts) —
    ///   não precisa da troca de coluna que as Sessões fazem.
    func layoutVisibility(isPortrait: Bool) -> NavigationSplitViewVisibility {
        switch destination {
        case .board:
            return .doubleColumn
        case .sessions:
            guard isPortrait else { return .all }
            return selection != nil ? .detailOnly : .doubleColumn
        case .machines:
            return (isPortrait && machineSelection != nil) ? .detailOnly : .all
        case .archive:
            return .all
        }
    }

    /// O ⤡ (e o ⌘⌃F): alterna entre tela cheia e o estado "aberto" do destino
    /// corrente.
    ///
    /// O estado aberto NÃO é `.all` em nenhum destino que tenha painel de
    /// detalhe:
    ///
    /// - no **Board** é `.doubleColumn`. Ali a lista de destinos vive na coluna
    ///   do MEIO (ver `RootSplitView.contentColumn`), então `.all` mostraria a
    ///   sidebar e a lista lado a lado: a mesma lista duas vezes, e o board
    ///   espremido numa terceira coluna.
    /// - em **Sessões e Máquinas** também é `.doubleColumn`, em QUALQUER
    ///   orientação (D4, 12/08/2026 — antes só valia em retrato; ver
    ///   `expandedVisibility`). Três colunas deixariam o terminal com um
    ///   filete e é justamente o oposto do que o ⤡ existe pra fazer. Duas
    ///   colunas ali são "sessões/máquinas | painel", com a sidebar unificada
    ///   atrás do ☰.
    func toggleColumns() {
        guard columnVisibility == .detailOnly else {
            columnVisibility = .detailOnly
            return
        }
        columnVisibility = expandedVisibility
    }

    /// O estado "aberto" do destino corrente — ver `toggleColumns()`.
    var expandedVisibility: NavigationSplitViewVisibility {
        switch destination {
        case .board:
            return .doubleColumn
        case .sessions, .machines:
            // D4 (12/08/2026): "aberto" é SEMPRE duas colunas aqui, em
            // qualquer orientação — não depende mais de `lastIsPortrait`.
            // Antes, paisagem devolvia `.all` (três colunas) e a coluna do
            // meio comia a largura que o terminal/painel de máquina
            // precisava; virou dispensável quando a barra de abas passou a
            // dar a navegação dentro do detalhe, então a sidebar unificada
            // fica sempre atrás do ☰ e "aberto" é "lista | painel".
            return .doubleColumn
        case .archive:
            return .all
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
        lastIsPortrait = isPortrait
        columnVisibility = layoutVisibility(isPortrait: isPortrait)
    }

    /// Última orientação vista por `applyLayoutRule` — a única memória de
    /// geometria desta classe. Não é `@Published`: ninguém desenha a partir
    /// dela, e publicá-la faria toda rotação invalidar a árvore inteira à toa.
    ///
    /// D4 (12/08/2026): desde que `expandedVisibility` parou de olhar
    /// orientação nas Sessões/Máquinas, este campo ficou sem nenhum leitor —
    /// só é escrito. Mantido aqui (não removido) porque não é o assunto desta
    /// task e apagar campo de estado não é decisão de uma task que só devia
    /// mudar uma função; sinalizado como candidato a remoção numa limpeza.
    ///
    /// Começa em `false` (paisagem) e é escrita antes de qualquer toque na tela
    /// — `RootSplitView` mede com `initial: true`, então a primeira medição
    /// acontece na montagem.
    private(set) var lastIsPortrait = false

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
