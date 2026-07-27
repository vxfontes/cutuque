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
    }

    /// Único ponto que chama `nav.applyLayoutRule` — os dois `.onChange`
    /// acima (tamanho medido mudando de verdade, ou destino/seleção mudando
    /// sem que a orientação mude por si só) convergem aqui pra não duplicar
    /// o guard. `LayoutRuleGate.shouldApply` é a decisão pura (testada em
    /// `WidthRuleGateTests`, sem hosting de View); aqui só decide COMO: marca
    /// `layoutRuleAppliedFor` ANTES de chamar `nav`, então se a própria regra
    /// colapsar a coluna e isso mudar `geo.size` de novo, a segunda entrada
    /// com a mesma chave já encontra o guard fechado — sem laço, sem
    /// reaplicar, sem sobrescrever a escolha manual da usuária.
    private func applyLayoutRuleIfNeeded() {
        guard lastKnownSize != nil,
              LayoutRuleGate.shouldApply(appliedFor: layoutRuleAppliedFor, key: layoutRuleKey)
        else { return }
        layoutRuleAppliedFor = layoutRuleKey
        nav.applyLayoutRule(isPortrait: isPortrait)
    }

    @ViewBuilder private var contentColumn: some View {
        switch nav.destination {
        case .sessions:
            SessionListView(splitSelection: $nav.selection)
        case .board:
            ContentUnavailableView("Board", systemImage: "rectangle.split.3x1",
                                   description: Text("Os filtros ficam no topo do board."))
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
            } else {
                ContentUnavailableView("Escolha uma sessão", systemImage: "list.bullet.rectangle",
                                       description: Text("A conversa e o terminal aparecem aqui."))
            }
        case .board:
            BoardView()
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
        .navigationTitle("Cutuque")
        .sheet(isPresented: $showingHistory) { HistoryView() }
        .sheet(isPresented: $showingSettings) { HubSettingsView() }
    }
}

/// Card arquivado no painel de detalhe (só leitura).
struct ArchivedTaskPane: View {
    let task: BoardTask
    @StateObject private var readOnlyModel = BoardModel()

    var body: some View {
        BoardTaskDetailView(task: task, model: readOnlyModel, readOnly: true)
    }
}

/// Decide SE a regra de layout (`NavigationState.applyLayoutRule`) deve
/// rodar agora — extraída do `RootSplitView` pra ser testável sem hosting de
/// View (`WidthRuleGateTests`). Renomeado de `WidthRuleGate` (regra dos 700
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

