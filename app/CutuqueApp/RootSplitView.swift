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
    // G6: as abas da coluna de detalhe (sessões ao vivo/chat). Mesma
    // instância injetada em `CutuqueApp.swift`.
    @EnvironmentObject private var tabsStore: OpenTabsStore

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

    /// Resolve as abas de máquina/arquivo que voltaram do disco só com a chave
    /// (ver `AbasResolver`). Sem isto elas girariam `ProgressView` pra sempre.
    @StateObject private var resolver = AbasResolver()

    /// Quais tipos estão esperando resolução AGORA — chave do `.task` abaixo,
    /// pra ele reentrar quando uma aba pendente nova aparecer (e não a cada
    /// repintura).
    private var chaveDePendentes: String {
        AbasResolucao.tiposPendentes(em: tabsStore.tabs.abas)
            .map(\.rawValue).sorted().joined(separator: ",")
    }

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

    /// Eixos que decidem o layout agora: destino, orientação e "tem aba
    /// escolhida". `paneMode` sai da chave de propósito — trocar Chat↔Terminal
    /// não pode mais mexer em `columnVisibility` (decisão explícita da
    /// usuária).
    ///
    /// [12/08/2026 — abas globais] Antes eram DOIS eixos, `nav.selection != nil`
    /// (Sessões) e `nav.machineSelection != nil` (Máquinas) — cada destino
    /// tinha a própria seleção guardando conexão viva, e por isso cada um
    /// entrava na chave. Hoje a barra de abas é global e `abaEmFoco` é o MESMO
    /// dado pros dois destinos (e pro Board também), então um eixo só basta. O
    /// motivo original de qualquer um deles estar aqui continua de pé: escolher
    /// algo (aba, sessão, host) não muda `geo.size` por si só — fora da chave,
    /// a regra nunca rodaria de novo e o painel abriria espremido na terceira
    /// coluna.
    private var layoutRuleKey: String {
        "\(nav.destination.rawValue)-\(isPortrait)-\(nav.abaEmFoco != nil)"
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
        // [12/08/2026] Mantém o `NavigationState` em dia com as abas — TRÊS
        // efeitos, um `.onChange` só (a terceira responsabilidade entrou no
        // mesmo dia, achados 1-3 da revisão da Task 5, funil de seleção).
        // `abaEmFoco` é o que faz `nav.paneMode` (a propriedade de
        // compatibilidade) continuar apontando pro modo que a usuária está
        // vendo agora, em vez de ficar preso na última aba que escreveu; o
        // descarte é a limpeza de `modosPorAba` (ver
        // `NavigationState.descartarModos`) — sem ela o dicionário cresceria
        // pra sempre a cada aba fechada. `initial: true` porque a primeira
        // aba (restaurada do disco ou aberta na hora) também precisa entrar
        // em foco sem esperar uma troca. Um handler SÓ, não um por aba: as
        // TRÊS escritas dependem do conjunto INTEIRO de abas, não de uma aba
        // isolada.
        //
        // A terceira: zera `nav.selection`/`machineSelection`/
        // `archiveSelection` quando a aba que as originou foi fechada (achado
        // 3 — ninguém fazia essa limpeza). Sem isto, fechar a aba pelo `✕`
        // deixava a linha correspondente realçada na lista/sidebar (realce
        // fantasma) e, em retrato, uma seleção de sessão órfã bloqueava
        // `sessionListLivesInDetail`/`AbasNavegacao.listaMoraNoDetalhe` — o
        // "lista | Nada aberto" relatado. `AbasNavegacao.selecoesOrfas` só
        // aponta quem está órfão; escrevemos `nil` SÓ nesses campos (os `if`
        // abaixo), pra não publicar as três `@Published` à toa a cada troca
        // de aba — a maioria não tem nada pra limpar. Zerar
        // `machineSelection`/`archiveSelection` aqui dispara os `.onChange`
        // deles logo abaixo, mas o `guard let` dos dois barra o `nil` antes de
        // qualquer `tabsStore.mutar` (conferido lendo o corpo dos dois) — não
        // há laço, e nenhuma aba fechada é reaberta por este handler.
        .onChange(of: tabsStore.tabs, initial: true) { _, tabs in
            nav.abaEmFoco = tabs.selecionada
            nav.descartarModos(mantendo: Set(tabs.abas.map(\.chave)))

            let orfas = AbasNavegacao.selecoesOrfas(
                abas: tabs.abas.map(\.chave), sessao: nav.selection,
                maquina: nav.machineSelection, arquivo: nav.archiveSelection)
            if orfas.sessao { nav.selection = nil }
            if orfas.maquina { nav.machineSelection = nil }
            if orfas.arquivo { nav.archiveSelection = nil }
        }
        // [12/08/2026 — abas globais] Tocar no destino Board abre/foca a ABA do
        // Board. Sem `initial: true`: o destino inicial é sempre `.sessions`, e
        // abrir uma aba na montagem atropelaria a aba restaurada do disco.
        .onChange(of: nav.destination) { _, destino in
            guard destino == .board else { return }
            tabsStore.mutar {
                $0.abrir(chave: .board, titulo: "Board", conteudo: .board)
            }
        }
        // Escolher um host na lista abre/foca a aba dele. `estilo: .passagem`
        // (padrão) é o modelo do VS Code: a próxima coisa aberta substitui esta
        // se ela não tiver sido fixada.
        .onChange(of: nav.machineSelection) { _, machine in
            guard let machine else { return }
            tabsStore.mutar {
                $0.abrir(chave: .maquina(machine.name), titulo: machine.name,
                         conteudo: .maquina(machine))
            }
        }
        .onChange(of: nav.archiveSelection) { _, card in
            guard let card else { return }
            tabsStore.mutar {
                $0.abrir(chave: .arquivado(card.id), titulo: card.title,
                         conteudo: .arquivado(card))
            }
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
        // Resolve as abas de máquina/arquivo restauradas do disco (ver
        // `AbasResolver`). `id: chaveDePendentes` reentra sempre que o CONJUNTO
        // de tipos pendentes muda — não a cada repintura — e o guard interno
        // evita tocar o hub quando não há ninguém esperando.
        .task(id: chaveDePendentes) {
            guard !chaveDePendentes.isEmpty else { return }
            await resolver.resolver(tabsStore)
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
    ///
    /// [12/08/2026 — abas globais] `tabsStore.tabs.selecionada == nil` entrou na
    /// conta: com a barra de abas na coluna de detalhe, "retrato sem seleção"
    /// deixou de significar "não há nada aberto". Sem esta condição, abrir uma
    /// aba pelo Board e voltar pra Sessões em retrato esconderia a aba aberta
    /// atrás da lista.
    ///
    /// [12/08/2026 — funil de seleção, achado 1 da revisão da Task 5] A conta
    /// virou `AbasNavegacao.listaMoraNoDetalhe` e `nav.selection` SAIU dela —
    /// ver o doc-comment completo lá, que preserva o raciocínio acima e explica
    /// por que checar `nav.selection` deixou de ser necessário (e era
    /// justamente essa checagem redundante que produzia "lista | Nada aberto"
    /// com uma seleção órfã de sessão fechada travando a condição).
    private var sessionListLivesInDetail: Bool {
        AbasNavegacao.listaMoraNoDetalhe(destino: nav.destination,
                                        abaSelecionada: tabsStore.tabs.selecionada,
                                        colunas: nav.columnVisibility)
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
        case .machines:
            MachineListView(splitSelection: $nav.machineSelection)
        case .archive:
            ArchiveView(embedded: true, selection: $nav.archiveSelection)
        }
    }

    /// [12/08/2026 — abas globais] A coluna de detalhe é a MESMA em todos os
    /// destinos: a barra de abas e os painéis abertos. O destino manda só na
    /// coluna do meio ("onde eu abro as coisas", o explorer do VS Code) — e é
    /// por isso que trocar de destino não fecha nem troca a aba escolhida.
    /// Os `switch nav.destination` que havia aqui (Board direto no detalhe,
    /// `MachineDetailView` do `machineSelection`, `ArchivedTaskPane` do
    /// `archiveSelection`) saíram: os três agora chegam como aba, pelos três
    /// `.onChange` (destino/`machineSelection`/`archiveSelection`) no `body`,
    /// acima. O `.id(machine.name)` que morava no case `.machines` continua
    /// vivo em `painel(_:)`, que é onde a máquina é renderizada agora.
    @ViewBuilder private var detailColumn: some View {
        if sessionListLivesInDetail {
            // Retrato, Sessões, nada aberto: a lista É o detalhe (ver
            // `sessionListLivesInDetail`). Tocar numa sessão abre a aba dela
            // (ver `SessionListView.apply`) e o painel toma a tela — o "ao
            // clicar, abre terminal tela cheia" do desenho.
            SessionListView(splitSelection: $nav.selection)
        } else {
            abasDetail
        }
    }

    /// A coluna de detalhe de TODOS os destinos (12/08/2026 — abas globais):
    /// barra de abas em cima (some quando não há nenhuma) e, embaixo, TODOS os
    /// painéis abertos montados num `ZStack`, alternando por opacidade. Trocar
    /// de aba não remonta nada — é o mesmo desenho que o `SessionDetailPane`
    /// já usa entre chat, terminal e informações, um nível abaixo (decisão
    /// #19). Renomeado de `sessionTabsDetail`: até aqui só a coluna de Sessões
    /// a usava; hoje é a coluna de detalhe inteira, de qualquer destino.
    @ViewBuilder private var abasDetail: some View {
        VStack(spacing: 0) {
            if !tabsStore.tabs.abas.isEmpty {
                TabBar(store: tabsStore)
            }
            ZStack {
                ForEach(tabsStore.tabs.abas) { aba in
                    let escolhida = tabsStore.tabs.selecionada == aba.chave
                    painel(aba)
                        .opacity(escolhida ? 1 : 0)
                        .allowsHitTesting(escolhida)
                        .accessibilityHidden(!escolhida)
                }
                if tabsStore.tabs.abas.isEmpty {
                    ContentUnavailableView("Nada aberto", systemImage: "square.on.square",
                                           description: Text("Toque numa sessão, no Board, numa máquina ou num card do arquivo."))
                }
            }
        }
    }

    /// O conteúdo de uma aba. `TabConteudo` é exaustivo por causa do modelo
    /// (`OpenTabs.swift`, G1); até 12/08/2026 só `.sessao` nascia de verdade —
    /// os outros casos existiam prontos, sem ninguém abrindo. Os três
    /// `.onChange` do `body` (Board/máquina/arquivo) fecham essa lacuna:
    /// agora todos os cinco tipos de aba nascem por algum caminho do app.
    @ViewBuilder private func painel(_ aba: AbaAberta) -> some View {
        switch aba.conteudo {
        case .sessao(let selection):
            SessionDetailPane(selection: selection,
                              paneState: tabsStore.tabs.estado(de: aba.chave),
                              chave: aba.chave)
        case .board:
            BoardView(embedded: true)
        case .maquina(let machine):
            // Mesmo motivo do antigo `.id(machine.name)` do case `.machines`:
            // identidade pelo NOME, não pela struct inteira (tema/ícone
            // mudariam o id e matariam o `ssh` por tabela). `paneState` é o
            // que faz a aba de máquina obedecer ao teto de 6 e parar de ler
            // quando sai de foco — num `ZStack` de abas o `onDisappear` dela
            // NUNCA roda (ver `MachineTerminalLifecycle`).
            NavigationStack {
                MachineDetailView(machine: machine,
                                  paneState: tabsStore.tabs.estado(de: aba.chave))
            }
            .id(machine.name)
        case .arquivado(let task):
            // `aoFechar` fecha a ABA. Zerar `nav.archiveSelection` (o que o
            // `ArchivedTaskPane` faz por padrão) não fecharia nada aqui — o
            // painel não vem mais da seleção — e o botão voltaria a ser
            // decorativo, que já foi bug relatado antes (12/08/2026).
            ArchivedTaskPane(task: task) { tabsStore.mutar { $0.fechar(aba.chave) } }
        case .pendente:
            // Erro de rede não mata aba (ver `AbasResolver`), então sobra o
            // caso de ficar girando pra sempre (host apagado antes do
            // resolver terminar, ou o próprio resolver que falhou): o botão é
            // a saída manual.
            VStack(spacing: 12) {
                ProgressView()
                Button("Tentar de novo") {
                    Task { await resolver.resolver(tabsStore) }
                }
                .buttonStyle(.bordered)
            }
        case .morta:
            abaMorta(aba.chave.tipo)
        }
    }

    /// D2: aviso, nunca recriação — fechar é decisão da Vanessa. O texto muda
    /// por tipo porque "Sessão encerrada" numa aba de máquina ou de card
    /// arquivado seria simplesmente falso (12/08/2026 — abas globais).
    @ViewBuilder private func abaMorta(_ tipo: TipoDeAba) -> some View {
        switch tipo {
        case .live, .chat, .board:
            ContentUnavailableView("Sessão encerrada", systemImage: "exclamationmark.triangle",
                                   description: Text("Essa sessão não está mais viva. A aba fica aqui até você fechá-la."))
        case .maquina:
            ContentUnavailableView("Máquina fora do registro", systemImage: "exclamationmark.triangle",
                                   description: Text("Esse host não está mais registrado no hub. A aba fica aqui até você fechá-la."))
        case .arquivado:
            ContentUnavailableView("Card não encontrado", systemImage: "exclamationmark.triangle",
                                   description: Text("Esse card não está mais no arquivo semanal. A aba fica aqui até você fechá-la."))
        }
    }
}

/// Sidebar. Sessões, Board e Arquivo são destinos de coluna; Histórico,
/// Ajustes e a Ajuda continuam em sheet — são telas de consulta pontual, não
/// valem uma reescrita pra virar coluna.
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
    @State private var showingHelp = false

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
                Button { showingHelp = true } label: {
                    Label("Como funciona", systemImage: "questionmark.circle")
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
        .sheet(isPresented: $showingHelp) { HelpView() }
    }
}

/// Card arquivado no painel de detalhe (só leitura).
struct ArchivedTaskPane: View {
    let task: BoardTask
    /// Quem fecha. `nil` = comportamento de sempre (zerar `nav.archiveSelection`);
    /// numa aba (12/08/2026 — abas globais), quem fecha é a aba, e quem passa o
    /// fechamento é `RootSplitView.painel(_:)`.
    var aoFechar: (() -> Void)?
    @EnvironmentObject private var nav: NavigationState
    @StateObject private var readOnlyModel = BoardModel()

    init(task: BoardTask, aoFechar: (() -> Void)? = nil) {
        self.task = task
        self.aoFechar = aoFechar
    }

    /// `onClose` fechando é o que faz o card FECHAR aqui. Sem ele o detalhe
    /// caía no `dismiss()` do ambiente — que numa coluna de split view não tem
    /// o que dispensar, então o botão era decorativo (relatado pela Vanessa: "o
    /// botão de fechar do card do arquivo semanal não ta fechando"). No iPhone
    /// o mesmo detalhe é um sheet e o `dismiss()` sempre funcionou, que é por
    /// que o furo demorou a aparecer. Fora de aba (`aoFechar == nil`), fechar
    /// continua sendo zerar `nav.archiveSelection`, o mesmo de sempre.
    private func fechar() {
        if let aoFechar { aoFechar() } else { nav.archiveSelection = nil }
    }

    var body: some View {
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true,
                            onClose: fechar)
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

