import SwiftUI

/// Raiz do app no iPad: UMA `NavigationSplitView` de três colunas, construída
/// uma vez e nunca substituída.
///
/// Girar o aparelho não troca nada de estrutura — o próprio componente recolhe
/// a sidebar em retrato e a mostra em paisagem. É isso que preserva o espelho
/// do tmux vivo e a rolagem do chat na rotação (decisão #19). Trocar a raiz por
/// orientação faria o SwiftUI remontar a árvore, e o `onDisappear` do terminal
/// chama `stop()` e `restoreSize()` — girar derrubaria o pane no servidor.
struct RootSplitView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var nav: NavigationState

    /// Chave do que já teve a regra de layout aplicada, pra ela valer UMA vez
    /// por entrada em destino/seleção/orientação e não brigar com o ⤡ da
    /// usuária.
    @State private var layoutRuleAppliedFor: String?

    /// Último tamanho do split view inteiro, medido pelo `.background` abaixo
    /// (mede sem participar do layout — não é o `detailColumn` que mede mais,
    /// ver nota da Task B). Cache necessário porque trocar de destino ou de
    /// seleção (ex.: Sessões → Board, ou escolher uma sessão) NÃO dispara uma
    /// nova medição de geometria por si só — só a rotação física do aparelho
    /// muda `geo.size`. Sem isto, a troca de `layoutRuleKey` não tinha
    /// nenhum tamanho pra reaplicar a regra contra. Ver
    /// `applyLayoutRuleIfNeeded()`.
    @State private var lastKnownSize: CGSize?

    /// Se a `NavigationSplitView` já terminou a primeira montagem. Enquanto
    /// for `false`, `applyLayoutRuleIfNeeded()` não escreve nada.
    ///
    /// Mexer em `columnVisibility` durante a primeira montagem não funciona: a
    /// split view RESPONDE escrevendo de volta no binding. Medido no
    /// simulador, não deduzido — em retrato o log mostrava a nossa escrita
    /// `all -> doubleColumn` e, 36 ms depois, `doubleColumn -> all` sem
    /// nenhuma chamada nossa no meio, e o iPad abria em TRÊS colunas. Depois
    /// de montada ela aceita: girar pra paisagem e voltar pro retrato aplicava
    /// `.doubleColumn` e o valor grudava, sem escrita de volta nenhuma.
    ///
    /// Duas saídas foram testadas na tela antes desta e as duas pioraram, por
    /// isso ficam registradas aqui:
    ///
    /// - **Reafirmar** `.doubleColumn` depois da escrita de volta deixava o
    ///   ESTADO certo (log confirmando) e a TELA errada: três trocas de
    ///   visibilidade em 39 ms faziam a coluna da esquerda renderizar vazia.
    ///   Com `Transaction.disablesAnimations` também.
    /// - **Filtrar o binding** (descartar a escrita de volta) divergia o layout
    ///   interno dela do nosso estado: ela mantinha a sidebar apresentada por
    ///   cima e a lista de destinos aparecia DUAS vezes.
    ///
    /// A diferença entre as duas e o caminho que funciona não é o valor final
    /// — é quantas vezes ele muda. Esperar a montagem dá UMA transição, a
    /// mesma da rotação.
    @State private var splitViewDidSettle = false

    /// `retrato = altura > largura`, lida do tamanho do próprio split view —
    /// não de `UIDevice.current.orientation` (devolve `.unknown`/`.faceUp` e
    /// exige notificação) nem de `horizontalSizeClass` (num iPad em tela
    /// cheia é `.regular` nas DUAS orientações). Funciona por construção em
    /// Slide Over e Split View estreito: a janela do app fica alta e estreita
    /// → lê como retrato → tela cheia, que é o comportamento certo lá.
    private var isPortrait: Bool {
        guard let size = lastKnownSize else { return false }
        return size.height > size.width
    }

    /// Eixos que decidem o layout agora: destino, orientação e "tem sessão
    /// escolhida". `paneMode` sai da chave de propósito — trocar
    /// Chat↔Terminal não pode mais mexer em `columnVisibility` (decisão
    /// explícita da usuária).
    private var layoutRuleKey: String {
        "\(nav.destination.rawValue)-\(isPortrait)-\(nav.selection != nil)"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            DestinationSidebar()
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        // Mede a proporção do split view sem afetar o layout — este
        // `.background(GeometryReader { Color.clear })` é o padrão a usar
        // (NÃO embrulhar a `NavigationSplitView` num `GeometryReader`, que
        // participaria do layout). Antes o `GeometryReader` vivia dentro do
        // `detail:` só pra medir a largura da coluna de detalhe pra regra dos
        // 700 pt; com o critério agora sendo orientação, não sobrou nada que
        // dependesse daquela medição — o `detailColumn` volta direto pro
        // `detail:` acima.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size, initial: true) { _, size in
                        lastKnownSize = size
                        applyLayoutRuleIfNeeded()
                    }
            }
        )
        // Critical herdado da regra dos 700 pt (agora sobre orientação):
        // trocar de destino ou de seleção (ex.: Sessões → Board tocando na
        // sidebar, ou escolher uma sessão, sem girar o aparelho) não muda
        // `geo.size` por si só, então o `.onChange` acima não disparava e a
        // regra nunca rodava pra chave nova — o Board podia abrir preso em
        // modo estreito (sem o botão de expandir que o Terminal tem, e sem
        // saída num iPad só de toque). Reaplica aqui contra o último tamanho
        // CONHECIDO (não uma medição nova), sob o MESMO guard de
        // `applyLayoutRuleIfNeeded()` — não há risco de aplicar duas vezes
        // nem de sobrescrever a escolha manual da usuária no ⤡, porque o
        // guard só deixa passar quando a chave é realmente nova.
        .onChange(of: layoutRuleKey) { _, _ in
            layoutRuleAppliedFor = nil
            applyLayoutRuleIfNeeded()
        }
        // Deep-link do push / Live Activity cai sempre em Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { nav.destination = .sessions }
        }
        // Libera a regra de layout só depois da primeira montagem da split
        // view (ver `splitViewDidSettle`). O `.task` já roda depois do
        // primeiro render; o `yield` cede mais uma volta do runloop pra ela
        // assentar antes de a gente escrever. Como o `.background` acima já
        // mediu o tamanho nesse meio tempo, a chamada aqui é o que aplica a
        // regra pela primeira vez — o guard de chave em
        // `applyLayoutRuleIfNeeded()` garante que seja uma vez só.
        .task {
            await Task.yield()
            splitViewDidSettle = true
            applyLayoutRuleIfNeeded()
        }
    }

    /// Único ponto que chama `nav.applyLayoutRule` — os dois `.onChange`
    /// acima (tamanho medido mudando de verdade, ou destino/seleção mudando
    /// sem que a orientação mude por si só) convergem aqui pra não duplicar
    /// o guard. `LayoutRuleGate.shouldApply` é a decisão pura (testada em
    /// `LayoutRuleGateTests`, sem hosting de View); aqui só decide COMO: marca
    /// `layoutRuleAppliedFor` ANTES de chamar `nav`, então se a própria regra
    /// colapsar a coluna e isso mudar `geo.size` de novo, a segunda entrada
    /// com a mesma chave já encontra o guard fechado — sem laço, sem
    /// reaplicar, sem sobrescrever a escolha manual da usuária.
    ///
    /// O `splitViewDidSettle` na frente é o que mantém a regra fora da
    /// primeira montagem (ver a propriedade). Antes dela a medição já chega e
    /// a chave já é a definitiva, mas escrever ali não pega — quem aplica a
    /// primeira vez é o `.task` acima.
    private func applyLayoutRuleIfNeeded() {
        guard splitViewDidSettle, lastKnownSize != nil,
              LayoutRuleGate.shouldApply(appliedFor: layoutRuleAppliedFor, key: layoutRuleKey)
        else { return }
        layoutRuleAppliedFor = layoutRuleKey
        nav.applyLayoutRule(isPortrait: isPortrait)
    }

    /// Em Sessões, a lista de sessões troca de coluna conforme a orientação: em
    /// paisagem ela é a coluna do MEIO das três ("sessoes e board | sessoes |
    /// terminal"); em retrato sem seleção o desenho da usuária pede DUAS
    /// colunas ("sessoes e board | sessoes listadas"), e aí ela vai pro
    /// DETALHE.
    ///
    /// A troca de coluna existe porque `.doubleColumn` numa split view de três
    /// colunas esconde a SIDEBAR, não a do meio (verificado na tela, não
    /// deduzido) — a mesma manobra do Board logo abaixo: o layout se faz por
    /// CONTEÚDO, não por visibilidade.
    ///
    /// A condição em `.doubleColumn` (e não só em "retrato sem seleção") tem a
    /// mesma razão do Board: o ☰ da split view continua na tela e revela a
    /// sidebar de verdade. Quando isso acontece a visibilidade vira `.all` e
    /// esta propriedade vira `false` na hora — a lista volta pro meio em vez de
    /// aparecer duas vezes, lado a lado.
    ///
    /// **Custo conhecido**: girar o iPad sem nada selecionado move a
    /// `SessionListView` entre colunas, e o SwiftUI remonta uma view que muda
    /// de lugar na árvore. Ela é dona do próprio `@StateObject`
    /// (`SessionListViewModel`), então isso significa modelo novo: um piscar de
    /// lista vazia e uma reconexão do WebSocket. Nada é perdido — o refresh é
    /// imediato — mas é real. Hospedar o modelo acima da split view resolveria;
    /// exige contagem de referência (`startLiveUpdates` tem
    /// `guard liveTask == nil`, então o start da instância nova seguido do stop
    /// da antiga deixaria o polling morto), e por isso ficou como tarefa
    /// separada. O terminal e o chat NÃO passam por isso: com seleção o painel
    /// nunca sai da coluna de detalhe (decisão #19).
    private var sessionListLivesInDetail: Bool {
        nav.destination == .sessions
            && nav.selection == nil
            && nav.columnVisibility == .doubleColumn
    }

    @ViewBuilder private var contentColumn: some View {
        switch nav.destination {
        case .sessions:
            if sessionListLivesInDetail {
                DestinationSidebar()
            } else {
                SessionListView(splitSelection: $nav.selection)
            }
        case .board:
            // Aqui mora o desenho da usuária pro Board: "sessoes e board |
            // board em si". Uma `NavigationSplitView` de TRÊS colunas não
            // sabe mostrar "sidebar + detalhe" — os três estados de
            // `NavigationSplitViewVisibility` são `.all` (as três),
            // `.doubleColumn` (esconde a SIDEBAR, não a do meio — verificado
            // na tela, não deduzido) e `.detailOnly`. Não existe um que
            // esconda só a coluna do meio.
            //
            // Então o layout se faz por conteúdo, não por visibilidade: em
            // `.doubleColumn` sobram coluna do meio + detalhe, e a do meio
            // — que ficou sem conteúdo quando os filtros voltaram pro topo
            // do kanban — passa a mostrar a própria lista de destinos. O
            // que a usuária vê é lista + board. A sidebar de verdade
            // continua existindo (a raiz nunca é substituída, decisão #19),
            // só escondida.
            //
            // A condição abaixo é o que impede o arranjo de se contradizer: o
            // ☰ da própria split view continua na tela e revela a sidebar de
            // verdade (`.toolbar(removing: .sidebarToggle)` não o remove aqui
            // — testado). Sem a condição, esse toque deixaria a MESMA lista
            // duas vezes, lado a lado, com o board espremido numa terceira
            // coluna. A invariante é: a lista só ocupa a coluna do meio
            // enquanto a sidebar está escondida.
            if nav.columnVisibility == .all {
                ContentUnavailableView("Board", systemImage: "rectangle.split.3x1",
                                       description: Text("Os filtros ficam no topo do board."))
            } else {
                DestinationSidebar()
            }
        case .archive:
            ArchiveView(embedded: true, selection: $nav.archiveSelection)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch nav.destination {
        case .sessions:
            if let selection = nav.selection {
                // .id força a troca de sessão a destruir o painel anterior — é
                // aí, e só aí, que o `restoreSize()` do terminal deve rodar.
                SessionDetailPane(selection: selection).id(selection)
            } else if sessionListLivesInDetail {
                // Retrato, nada escolhido: a lista É o detalhe (ver
                // `sessionListLivesInDetail`). Tocar numa sessão troca a
                // visibilidade pra `.detailOnly` e o painel toma a tela — o
                // "ao clicar, abre terminal tela cheia" do desenho.
                SessionListView(splitSelection: $nav.selection)
            } else {
                ContentUnavailableView("Escolha uma sessão", systemImage: "list.bullet.rectangle",
                                       description: Text("A conversa e o terminal aparecem aqui."))
            }
        case .board:
            // `embedded`: sem `NavigationStack` próprio aqui dentro — numa
            // coluna da split view a barra dele é engolida e título, busca,
            // recarregar e o menu "⋯" somem (ver `BoardView.embedded`).
            BoardView(embedded: true)
        case .archive:
            if let task = nav.archiveSelection {
                ArchivedTaskPane(task: task)
            } else {
                ContentUnavailableView("Escolha um card", systemImage: "archivebox",
                                       description: Text("Os concluídos das semanas fechadas ficam aqui."))
            }
        }
    }
}

/// Sidebar. Sessões, Board e Arquivo são destinos de coluna; Histórico e
/// Ajustes continuam em sheet — são telas de consulta pontual, não valem uma
/// reescrita pra virar coluna.
///
/// Aparece em DOIS lugares, e de propósito: na coluna de sidebar da raiz e,
/// no destino Board, na coluna do meio (ver `contentColumn`). Só uma das
/// duas está visível de cada vez — no Board a sidebar de verdade fica
/// escondida por `.doubleColumn` e o ☰ é removido de lá. São duas instâncias
/// da mesma view, com `@State` independente, o que aqui é inofensivo: os
/// sheets de Histórico/Ajustes pertencem a quem foi tocado.
///
/// O **status do hub** de propósito NÃO está aqui: a `HubStatusView` precisa
/// das sessões já carregadas (`sessions:`/`live:`) pro resumo, e a sidebar não
/// as tem. Ele fica onde sempre esteve, na toolbar da lista de sessões, com os
/// dados de verdade e o indicador colorido.
struct DestinationSidebar: View {
    @EnvironmentObject private var nav: NavigationState
    @State private var showingHistory = false
    @State private var showingSettings = false

    /// `List(selection:)` só existe para binding OPCIONAL; `nav.destination` é
    /// não-opcional de propósito (sempre há um destino escolhido — contrato da
    /// Task 5, coberto em `NavigationStateTests`). Aqui só embrulha/desembrulha
    /// pra casar com a API do List — a seleção nunca fica nil de verdade.
    private var destinationBinding: Binding<PadDestination?> {
        Binding(
            get: { nav.destination },
            set: { if let newValue = $0 { nav.destination = newValue } }
        )
    }

    var body: some View {
        List(selection: destinationBinding) {
            Section {
                ForEach(PadDestination.allCases) { destination in
                    Label(destination.label, systemImage: destination.symbol)
                        .tag(destination)
                }
            }
            Section {
                Button { showingHistory = true } label: {
                    Label("Histórico", systemImage: "clock.arrow.circlepath")
                }
                Button { showingSettings = true } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
            }
            .buttonStyle(.plain)
        }
        // Explícito porque esta view também vive na coluna do MEIO (Board),
        // onde o padrão seria `.insetGrouped` e a lista destoaria da mesma
        // lista renderizada na coluna de sidebar. Na sidebar é redundante.
        .listStyle(.sidebar)
        .navigationTitle("Cutuque")
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .sheet(isPresented: $showingSettings) { HubSettingsView() }
    }
}

/// Card arquivado no painel de detalhe (só leitura).
struct ArchivedTaskPane: View {
    let task: BoardTask
    @EnvironmentObject private var nav: NavigationState
    @StateObject private var readOnlyModel = BoardModel()

    /// `onClose` zerando a seleção é o que faz o card FECHAR aqui. Sem ele o
    /// detalhe caía no `dismiss()` do ambiente — que numa coluna de split view
    /// não tem o que dispensar, então o botão era decorativo (relatado pela
    /// Vanessa: "o botão de fechar do card do arquivo semanal não ta
    /// fechando"). No iPhone o mesmo detalhe é um sheet e o `dismiss()`
    /// sempre funcionou, que é por que o furo demorou a aparecer.
    var body: some View {
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true,
                            onClose: { nav.archiveSelection = nil })
    }
}

/// Decide SE a regra de layout (`NavigationState.applyLayoutRule`) deve
/// rodar agora — extraída do `RootSplitView` pra ser testável sem hosting de
/// View (`LayoutRuleGateTests`). Renomeado de `WidthRuleGate` (regra dos 700
/// pt): a decisão em si (guard de chave) não mudou, só o que vai na `key` —
/// antes destino+painel, agora destino+orientação+seleção.
///
/// `appliedFor` é a chave que já recebeu a regra (`nil` = nenhuma ainda);
/// `key` é a chave corrente de destino/orientação/seleção. A validade da
/// medição (há um `lastKnownSize` conhecido?) é responsabilidade de quem
/// chama (`applyLayoutRuleIfNeeded()`), não deste guard — aqui só a
/// comparação de chaves. Mesmo guard serve os dois gatilhos que podem levar
/// a uma reaplicação: o tamanho medido mudando de verdade (rotação), e
/// destino/seleção mudando sem que a orientação mude por si só (o Critical
/// original desta correção, herdado da regra dos 700 pt).
enum LayoutRuleGate {
    static func shouldApply(appliedFor: String?, key: String) -> Bool {
        appliedFor != key
    }
}

