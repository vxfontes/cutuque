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
    case terminal, files, diff, codeServer

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files:    return "Arquivos"
        case .diff:     return "Diff"
        case .codeServer: return "Editor"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "apple.terminal"
        case .files:    return "folder"
        case .diff:     return "arrow.left.arrow.right"
        case .codeServer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Chave do `@AppStorage` que lembra o painel deste host.
    static func storageKey(machine: String) -> String {
        "cutuque.machinePane.\(machine)"
    }
}

/// Um botão do seletor que a `ChromeDaAba` desenha embaixo da barra de abas.
///
/// [13/08/2026] O seletor de painel morava em `ToolbarItem(placement: .principal)`
/// DENTRO de cada painel. Pela decisão #19 os painéis do iPad ficam montados
/// para sempre (alterna-se opacidade num `ZStack`, para não derrubar o `ssh`/o
/// espelho do tmux) — então N painéis contribuíam itens para a MESMA navigation
/// bar, e o SwiftUI escondia quase todos: "não ta aparecendo o terminal / info
/// embaixo da aba em terminais live e tal".
///
/// A saída é inverter o fluxo: o painel não DESENHA seletor nenhum, ele
/// **declara** quais segmentos tem (`NavigationState.definirSegmentos`); a
/// chrome — uma só, fora dos painéis — desenha os da aba em foco e escreve a
/// escolha de volta. `id` é o `rawValue` do enum de painel de quem declarou
/// (`PaneMode`/`MachinePane`), que é como o painel traduz a escolha de volta
/// pro seu próprio estado.
struct SegmentoDeChrome: Identifiable, Equatable, Hashable {
    let id: String
    let titulo: String
    let simbolo: String

    /// O id do PRÓXIMO segmento, ciclando — a conta do ⌘⇧T, pura de propósito
    /// (dá para afirmar sem montar view nem `NavigationState`).
    ///
    /// `escolha` é o valor CRU guardado (`NavigationState.escolha(de:)`), que pode
    /// ser um id que NÃO existe nesta aba: é o que acontece numa aba ao vivo que
    /// herdou `"chat"` de um escritor antigo. Nesse caso o ponto de partida é o
    /// primeiro segmento — a mesma regra do getter do `Picker` da `ChromeDaAba`,
    /// isto é, o que a usuária está VENDO destacado. Alternar a partir do valor
    /// cru em vez do visível era justamente o no-op silencioso do card
    /// `957a6ff8c71fcee0`.
    ///
    /// Devolve `nil` quando não há como alternar (0 ou 1 segmento): aí o chamador
    /// não deve escrever nada, senão a chrome guardaria escolha para uma aba que
    /// não tem seletor.
    static func proximo(depoisDe escolha: String?, entre segmentos: [SegmentoDeChrome]) -> String? {
        guard segmentos.count > 1 else { return nil }
        let atual = escolha.flatMap { id in segmentos.firstIndex(where: { $0.id == id }) } ?? 0
        return segmentos[(atual + 1) % segmentos.count].id
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
    /// [Reescrito em 12/08/2026 — abas globais] Trocar de destino NÃO limpa
    /// mais `selection`/`machineSelection`.
    ///
    /// A limpeza existia por duas razões que a barra de abas global desfez. A
    /// primeira: "sair pro Board e voltar pra Sessões caía direto na última
    /// sessão aberta em vez da lista" — em retrato a regra de layout colapsava
    /// pra `.detailOnly` quando havia seleção. Hoje quem decide o colapso é
    /// `abaEmFoco` (ver `layoutVisibility`), e cair na coisa que estava aberta é
    /// exatamente o desenho pedido: "voltar pra Sessões troca a LISTA, não a aba
    /// escolhida". A segunda: "as duas guardam conexão viva — sair da coluna
    /// destrói o painel, e voltar reabriria um terminal NOVO com cara do
    /// antigo". Também deixou de valer: o painel não mora mais na coluna do
    /// destino, mora na aba, e quem manda no `ssh`/no espelho é
    /// `OpenTabs.estado(de:)` (ver `MachineTerminalLifecycle`). Limpar aqui
    /// hoje só dessincronizaria a lista (sem linha destacada) da aba que segue
    /// aberta.
    @Published var destination: PadDestination = .sessions
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
    ///
    /// [13/08/2026] Também mantém a escolha da chrome em sincronia, e é aqui
    /// (não em cada painel) de propósito. `escolhaPorAba` é um cache paralelo:
    /// qualquer escritor de modo que não passe pelo Picker da `ChromeDaAba` o
    /// deixaria órfão, e o sintoma é o seletor da faixa MENTINDO sobre o
    /// conteúdo — destacando "Chat" com o Terminal na tela. Existem dois
    /// escritores desses: o ✕ de fechar o terminal (`SessionDetailPane` grava
    /// `.info` direto) e o ⌘⇧T do menu (`CutuqueCommands`, pela propriedade
    /// `paneMode` abaixo). Consertar no único ponto por onde os dois passam faz
    /// a invariante valer por construção, em vez de depender de cada painel
    /// lembrar de um `.onChange` a mais. Vale a convenção que a chrome já usa:
    /// o `id` do segmento de uma aba de sessão É o `rawValue` do `PaneMode`
    /// (ver `SessionDetailPaneLogic.segmentosDeChrome`).
    ///
    /// O guarda de igualdade não é enfeite: pela decisão #19 os N painéis ficam
    /// montados, então cada `objectWillChange` daqui recompõe todos eles.
    func definirPaneMode(_ modo: PaneMode, de chave: ChaveDeAba?) {
        guard let chave else {
            guard modoSemAba != modo else { return }
            modoSemAba = modo
            return
        }
        guard modosPorAba[chave] != modo else { return }
        modosPorAba[chave] = modo
        escolher(modo.rawValue, de: chave)
    }

    /// Propriedade de COMPATIBILIDADE: o modo da aba em foco (`abaEmFoco`).
    /// É o que mantém `CutuqueCommands` (⌘⇧T e o item de menu) e o iPhone
    /// (sem abas, `abaEmFoco` fica sempre `nil`) compilando e funcionando
    /// sem saber que o modo virou por-aba — os dois só conhecem
    /// `nav.paneMode`, nunca `paneMode(de:)`.
    ///
    /// Não é mais `@Published`: é COMPUTADA sobre `modosPorAba`/`modoSemAba`,
    /// que são os `@Published` de verdade. Consequência real: `$nav.paneMode`
    /// deixou de existir. O único lugar que usava o binding era o `Picker` do
    /// seletor de painel — que, na época, morava dentro de `SessionDetailPane`.
    /// [Atualizado em 13/08/2026] O `Picker` mudou de casa: saiu do painel e foi
    /// pra `ChromeDaAba`, uma barra só para todas as abas, porque N painéis
    /// montados (decisão #19) contribuindo pra MESMA navigation bar faziam o
    /// SwiftUI esconder quase todos ("não ta aparecendo o terminal / info
    /// embaixo da aba"). O `Binding(get:set:)` manual continua existindo, agora
    /// em `ChromeDaAba.escolhaBinding`, e o painel só LÊ `nav.escolha(de:)`.
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

    // MARK: - Registro da chrome da aba

    /// Os segmentos que o conteúdo de cada aba DECLAROU ter (ver
    /// `SegmentoDeChrome`). Quem escreve é o painel, quem lê é a `ChromeDaAba` —
    /// nunca o contrário.
    ///
    /// É dado puro, de propósito. As duas alternativas óbvias não servem:
    /// `PreferenceKey` sobe pela árvore e COMBINA os N painéis montados, que é
    /// exatamente o defeito da toolbar que isto vem consertar; e guardar
    /// closures dos painéis aqui criaria ciclo de retenção
    /// (`NavigationState` → closure → view → `nav`).
    @Published private var segmentosPorAba: [ChaveDeAba: [SegmentoDeChrome]] = [:]
    /// O `id` do segmento escolhido em cada aba. Separado de `modosPorAba` de
    /// propósito: aqui é `String` crua (a chrome não conhece `PaneMode` nem
    /// `MachinePane`), e traduzir de volta pro enum é trabalho do painel.
    @Published private var escolhaPorAba: [ChaveDeAba: String] = [:]

    /// Declara os segmentos de `chave`. Idempotente: escrever valor IGUAL não
    /// publica mudança.
    ///
    /// O guarda de igualdade não é otimização, é correção. Os painéis chamam
    /// isto de `.task`/`.onChange`, que rodam a cada recomposição — publicar um
    /// valor igual dentro de uma atualização de view é laço de atualização
    /// ("Publishing changes from within view updates").
    func definirSegmentos(_ segmentos: [SegmentoDeChrome], de chave: ChaveDeAba) {
        guard segmentosPorAba[chave] != segmentos else { return }
        segmentosPorAba[chave] = segmentos
    }

    /// Os segmentos declarados por `chave` — vazio para `nil` (iPhone, que não
    /// usa abas nem chrome) e para aba que ainda não declarou nada. Mesmo
    /// contrato de `paneMode(de:)`: nunca inventa valor de outra aba.
    func segmentos(de chave: ChaveDeAba?) -> [SegmentoDeChrome] {
        guard let chave else { return [] }
        return segmentosPorAba[chave] ?? []
    }

    /// Escreve a escolha da aba. Idempotente, pela mesma razão de
    /// `definirSegmentos`.
    ///
    /// Não valida `id` contra os segmentos declarados: a chrome escreve sempre
    /// um `id` que ela própria acabou de desenhar, e o painel já valida o modo
    /// na hora de renderizar (`SessionDetailPaneLogic.modoValido`).
    func escolher(_ id: String, de chave: ChaveDeAba) {
        guard escolhaPorAba[chave] != id else { return }
        escolhaPorAba[chave] = id
    }

    /// A escolha guardada de `chave`, ou `nil` se a aba nunca escolheu nada —
    /// aí quem decide o padrão é o painel, que é o único que sabe qual dos seus
    /// segmentos faz sentido abrir primeiro (`entryPaneMode`).
    func escolha(de chave: ChaveDeAba?) -> String? {
        guard let chave else { return nil }
        return escolhaPorAba[chave]
    }

    /// ⌘⇧T: avança para o próximo segmento da aba em foco — Terminal→Info numa
    /// aba ao vivo, Chat→Terminal→Info numa de sessão com chat, Terminal→Arquivos
    /// numa de máquina. Escreve pelo MESMO caminho da chrome (`escolher`), e é por
    /// isso que os painéis reagem: `SessionDetailPane` e `MachineDetailView` têm
    /// ambos um `.onChange(of: nav.escolha(de:))`.
    ///
    /// [13/08/2026] Antes o atalho fazia, no `CutuqueCommands`,
    /// `nav.paneMode = nav.paneMode == .chat ? .terminal : .chat`. Numa aba AO VIVO
    /// (segmentos Terminal↔Info, sem chat) isso escrevia `.chat`, o painel clampava
    /// de volta para `.terminal` na renderização (`modoValido`) e **o atalho não
    /// fazia nada, sem nenhum sinal** — card `957a6ff8c71fcee0`. E deixava a
    /// escolha da chrome valendo `"chat"`, um id que não existe entre os segmentos
    /// daquela aba: o "seletor mentindo sobre o conteúdo" que `definirPaneMode`
    /// existe para evitar.
    ///
    /// Perguntar os segmentos à aba, em vez de codificar dois modos aqui, é o que
    /// faz o atalho servir a aba de máquina de graça — e continuar certo quando
    /// alguém acrescentar um segmento novo.
    func alternarSegmento() {
        guard let chave = abaEmFoco else {
            // iPhone (e qualquer leitor sem aba): não há chrome nem segmentos
            // declarados, então segue valendo o alterna de sempre entre os dois
            // painéis que existem ali.
            paneMode = paneMode == .chat ? .terminal : .chat
            return
        }
        guard let proximo = SegmentoDeChrome.proximo(
            depoisDe: escolha(de: chave), entre: segmentos(de: chave)
        ) else { return }
        escolher(proximo, de: chave)
    }

    /// Esquece o chrome de UMA aba — usado quando o conteúdo dela muda de
    /// natureza, não só quando ela fecha.
    func limparChrome(de chave: ChaveDeAba) {
        guard segmentosPorAba[chave] != nil || escolhaPorAba[chave] != nil else { return }
        segmentosPorAba[chave] = nil
        escolhaPorAba[chave] = nil
    }

    /// Descarta o chrome de abas que não existem mais — mesmo motivo e mesmo
    /// ponto de chamada de `descartarModos(mantendo:)`, no
    /// `.onChange(of: tabsStore.tabs)` do `RootSplitView`.
    func descartarChrome(mantendo vivas: Set<ChaveDeAba>) {
        let segmentosVivos = segmentosPorAba.filter { vivas.contains($0.key) }
        if segmentosVivos.count != segmentosPorAba.count { segmentosPorAba = segmentosVivos }
        let escolhasVivas = escolhaPorAba.filter { vivas.contains($0.key) }
        if escolhasVivas.count != escolhaPorAba.count { escolhaPorAba = escolhasVivas }
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
            // [12/08/2026 — abas globais] Era `selection != nil`. O sinal de
            // "tem coisa aberta" mudou de lugar: quem mostra o painel agora é a
            // barra de abas, e ela é global — voltar pra Sessões com uma aba de
            // máquina em foco tem de continuar em tela cheia, e uma sessão
            // "selecionada" na lista sem aba nenhuma escolhida não é nada
            // aberto. `abaEmFoco` é o mesmo dado que `nav.paneMode` já usa.
            return abaEmFoco != nil ? .detailOnly : .doubleColumn
        case .machines:
            // Mesma troca de sinal do caso acima (era `machineSelection != nil`).
            return (isPortrait && abaEmFoco != nil) ? .detailOnly : .all
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
