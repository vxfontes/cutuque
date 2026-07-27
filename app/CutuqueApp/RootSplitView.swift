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

    /// Chave do que já teve a regra dos 700 pt aplicada, pra ela valer UMA vez
    /// por entrada em destino/painel e não brigar com o ⤡ da usuária.
    @State private var widthRuleAppliedFor: String?

    /// Última largura da coluna de detalhe medida pelo `GeometryReader` do
    /// `detail:`. Cache necessário porque trocar de destino (ex.: Sessões →
    /// Board) NÃO muda essa largura por si só — a proporção das colunas só
    /// reage a `columnVisibility`, que é justamente o que a regra decide.
    /// Sem isto, a troca de `widthRuleKey` não tinha nenhuma largura pra
    /// reaplicar a regra contra. Ver `applyWidthRuleIfNeeded()`.
    @State private var lastKnownWidth: CGFloat?

    private var widthRuleKey: String { "\(nav.destination.rawValue)-\(nav.paneMode.rawValue)" }

    var body: some View {
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            DestinationSidebar()
        } content: {
            contentColumn
        } detail: {
            GeometryReader { geo in
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        lastKnownWidth = width
                        applyWidthRuleIfNeeded()
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Critical corrigido aqui: trocar de destino/painel (ex.: Sessões →
        // Board tocando na sidebar, sem girar o aparelho) não muda
        // `geo.size.width` por si só, então o `.onChange` acima não disparava
        // e a regra dos 700 pt nunca rodava pra chave nova — o Board podia
        // abrir preso em modo estreito (sem o botão de expandir que o
        // Terminal tem, e sem saída num iPad só de toque). Reaplica aqui
        // contra a última largura CONHECIDA (não uma medição nova), sob o
        // MESMO guard de `applyWidthRuleIfNeeded()` — não há risco de aplicar
        // duas vezes nem de sobrescrever a escolha manual da usuária no ⤡,
        // porque o guard só deixa passar quando a chave é realmente nova.
        .onChange(of: widthRuleKey) { _, _ in
            widthRuleAppliedFor = nil
            applyWidthRuleIfNeeded()
        }
        // Deep-link do push / Live Activity cai sempre em Sessões.
        .onChange(of: router.pendingSessionID) { _, id in
            if id != nil { nav.destination = .sessions }
        }
    }

    /// Único ponto que chama `nav.applyWidthRule` — os dois `.onChange`
    /// acima (largura medida mudando, destino/painel mudando) convergem
    /// aqui pra não duplicar o guard. `WidthRuleGate.shouldApply` é a
    /// decisão pura (testada em `WidthRuleGateTests`, sem hosting de View);
    /// aqui só decide COMO: marca `widthRuleAppliedFor` ANTES de chamar
    /// `nav`, então se a própria regra colapsar a coluna e isso mudar
    /// `geo.size.width` de novo, a segunda entrada com a mesma chave já
    /// encontra o guard fechado — sem laço, sem reaplicar, sem sobrescrever
    /// a escolha manual da usuária.
    private func applyWidthRuleIfNeeded() {
        guard let width = lastKnownWidth,
              WidthRuleGate.shouldApply(appliedFor: widthRuleAppliedFor, key: widthRuleKey, width: width)
        else { return }
        widthRuleAppliedFor = widthRuleKey
        nav.applyWidthRule(detailWidth: width)
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

/// Decide SE a regra dos 700 pt (`NavigationState.applyWidthRule`) deve
/// rodar agora — extraída do `RootSplitView` pra ser testável sem hosting de
/// View (`WidthRuleGateTests`).
///
/// `appliedFor` é a chave que já recebeu a regra (`nil` = nenhuma ainda);
/// `key` é a chave corrente de destino/painel; `width` é a última largura
/// CONHECIDA da coluna de detalhe (pode vir de uma medição nova ou de um
/// cache — quem chama decide). Mesmo guard serve os dois gatilhos que podem
/// levar a uma reaplicação: a largura medida mudando, e o destino/painel
/// mudando sem que a largura mude por si só (o Critical desta correção).
enum WidthRuleGate {
    static func shouldApply(appliedFor: String?, key: String, width: CGFloat?) -> Bool {
        guard let width, width > 0 else { return false }
        return appliedFor != key
    }
}

