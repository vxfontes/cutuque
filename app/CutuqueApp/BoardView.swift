import SwiftUI

// MARK: - ViewModel

/// Estado do Cutuque Board no app: carrega os cards do hub e executa as ações
/// (mover, marcar encalhada, comentar, apagar). Sem WebSocket — carrega no
/// aparecer e no pull-to-refresh, e re-carrega após cada ação.
@MainActor
final class BoardModel: ObservableObject {
    @Published var tasks: [BoardTask] = []
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var searchResults: [BoardTask] = []
    @Published var closeOptions: CloseOptions?

    // Filtros (E), espelham o dashboard web.
    @Published var filterGroup = "all"
    @Published var filterType = "all"
    @Published var filterSession = "all"

    private let api = APIClient()

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { tasks = try await api.boardTasks(); errorText = nil }
        catch { errorText = "Não consegui carregar o board." }
    }

    func move(_ task: BoardTask, to column: BoardColumn) async {
        do { try await api.moveBoardTask(id: task.id, column: column.rawValue); await load() }
        catch { errorText = "Falha ao mover o card." }
    }

    /// Arraste: move na hora, na lista local, e só então fala com o hub. Sem
    /// isto o card voltaria visivelmente pra origem antes de reaparecer no
    /// destino — o board não tem WebSocket, toda ação recarrega tudo.
    func drop(_ task: BoardTask, on target: BoardDropTarget) async {
        guard let plan = BoardMoveLogic.plan(for: task, target: target) else { return }
        let snapshot = tasks
        tasks = BoardMoveLogic.apply(plan, to: tasks, id: task.id)
        do {
            switch plan {
            case .move(let column):
                try await api.moveBoardTask(id: task.id, column: column.rawValue)
            case .markEncalhada:
                try await api.setBoardEncalhada(id: task.id, true)
            }
            await load()
        } catch {
            tasks = snapshot
            errorText = "Não consegui mover o card — ele voltou pro lugar."
        }
    }

    /// Acha o card pelo id (o arraste carrega só o id, que é o que `String`
    /// sabe transferir sem conformidade nova).
    func task(id: String) -> BoardTask? { tasks.first { $0.id == id } }

    func markEncalhada(_ task: BoardTask) async {
        do { try await api.setBoardEncalhada(id: task.id, true); await load() }
        catch { errorText = "Falha ao marcar como encalhada." }
    }
    func comment(_ task: BoardTask, text: String) async {
        do { try await api.addBoardComment(id: task.id, author: "você", text: text); await load() }
        catch { errorText = "Falha ao comentar." }
    }
    func delete(_ task: BoardTask) async {
        do { try await api.deleteBoardTask(id: task.id); await load() }
        catch { errorText = "Falha ao apagar o card." }
    }
    func closeWeek(week: String = "") async {
        do { try await api.closeWeek(week: week); closeOptions = nil; await load() }
        catch { errorText = "Falha ao fechar a semana." }
    }

    /// Busca ONDE dá pra arquivar antes de perguntar. Falha de rede não trava o
    /// fechamento: sem opções, o popup vira o confirmar de sempre.
    func loadCloseOptions() async {
        closeOptions = try? await api.closeOptions()
    }
    func search(_ q: String) async {
        let term = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { searchResults = []; return }
        searchResults = (try? await api.searchBoard(term)) ?? []
    }

    // Valores distintos para os filtros.
    var groups: [String] { distinct(\.group) }
    var types: [String] { tasks.compactMap { $0.type }.filter { !$0.isEmpty }.uniqued().sorted() }
    var sessions: [String] { distinct(\.session) }
    private func distinct(_ kp: KeyPath<BoardTask, String>) -> [String] {
        tasks.map { $0[keyPath: kp] }.filter { !$0.isEmpty }.uniqued().sorted()
    }

    private func passesFilters(_ t: BoardTask) -> Bool {
        (filterGroup == "all" || t.group == filterGroup) &&
        (filterType == "all" || (t.type ?? "") == filterType) &&
        (filterSession == "all" || t.session == filterSession)
    }

    // Agrupamentos (já filtrados).
    var encalhadas: [BoardTask] {
        tasks.filter { $0.isEncalhada && passesFilters($0) }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
    func inColumn(_ column: BoardColumn) -> [BoardTask] {
        tasks.filter { $0.column == column.rawValue && !($0.isEncalhada && column == .aFazer) && passesFilters($0) }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
    var hasActiveFilter: Bool { filterGroup != "all" || filterType != "all" || filterSession != "all" }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var s = Set<Element>(); return filter { s.insert($0).inserted } }
}

// MARK: - Board estilo Trello (colunas horizontais com swipe)

struct BoardView: View {
    /// `true` quando o board já vive dentro de uma coluna da
    /// `NavigationSplitView` do iPad — e aí ele NÃO cria `NavigationStack`
    /// próprio. Mesmo parâmetro (e mesmo motivo) da `ArchiveView`.
    ///
    /// O motivo é um achado de tela: **um `NavigationStack` aninhado numa
    /// coluna da split view tem a barra engolida pelo iPadOS**. Título, campo
    /// de busca, botão de recarregar e o menu "⋯" (Arquivo semanal / Fechar
    /// semana) existiam, eram montados, e não chegavam à tela — sobrava só o
    /// espaço vazio deles ("tem muito espaço vago aqui por cima"). Ou seja:
    /// não era só espaço morto, eram quatro controles inalcançáveis no iPad.
    /// Sem o stack aninhado, os modificadores vão pra barra da própria coluna
    /// e aparecem. Mesma família do `.inspector` que não renderiza a barra do
    /// `NavigationStack` que apresenta (ver `BoardTaskDetailView`).
    var embedded: Bool = false
    // Injetado pelo app — mesmo modelo em iPhone e iPad.
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var nav: NavigationState
    @State private var showCloseWeekConfirm = false
    @State private var showArchive = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    // Foco do campo de busca própria, pra atender `.focusSearch` — a
    // `BoardView` é a única dona de filtros e busca agora (coluna do meio
    // apagada; ver decisão da usuária no brief da correção de layout).
    @FocusState private var searchFieldFocused: Bool

    // Idiom: nunca muda em runtime (mesmo valor que escolhe a raiz do app em
    // `CutuqueApp.swift`). Só alimenta a paginação por swipe do
    // `boardScroller` (via `BoardLayout.isRegularWidth`) — filtros e busca
    // agora são sempre da `BoardView`, em qualquer idiom, já que a coluna de
    // filtros do meio (`BoardFilterList`) foi removida e não sobrou nenhum
    // outro predicado de estrutura que dependesse do idiom aqui.
    private var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // Estado do card selecionado mora no NavigationState compartilhado (não
    // num @State local) porque também é lido pela regra dos 700 pt / abertura
    // via deep link no iPad — não é exclusivo desta view.
    private var selected: BoardTask? {
        get { nav.boardSelection }
        nonmutating set { nav.boardSelection = newValue }
    }

    var body: some View {
        if embedded {
            boardContent
        } else {
            NavigationStack {
                boardContent
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Buscar título, descrição, comentários…")
                    .modifier(SearchFocusWhenAvailable(focused: $searchFieldFocused))
            }
        }
    }

    /// A busca do iPad, larga, na posição principal da barra — desenho da
    /// usuária: "nem precisa estar escrito cutuque board, pode deixar a busca
    /// full size com os dois botoes da direita".
    ///
    /// É um campo próprio, não `.searchable`, e de propósito: com
    /// `placement: .toolbar` o iPadOS entrega um capsule estreito ENCOSTADO na
    /// direita, com os botões à esquerda dele — o contrário do pedido
    /// (verificado na tela). Aqui o custo de trocar é baixo porque a busca
    /// deste board já era toda nossa: o texto é debounced em 250 ms, vai pra
    /// `model.search`, e `isSearching` é quem troca o conteúdo. Do
    /// `.searchable` só se perde o "Cancelar" do sistema, substituído pelo ✕.
    ///
    /// O iPhone continua com `.searchable` na gaveta, intocado.
    private var padSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Buscar título, descrição, comentários…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .frame(minWidth: 320, idealWidth: 640, maxWidth: 640)
    }

    @ViewBuilder private var boardContent: some View {
            Group {
                if isSearching {
                    // A busca sempre toma a tela quando há termo digitado —
                    // única dona da busca agora é a `BoardView`, em qualquer
                    // idiom (a coluna de filtros do meio foi removida; a
                    // decisão da usuária foi "filtros sempre em cima").
                    searchResultsView
                } else {
                    VStack(spacing: 0) {
                        FilterBar(model: model)
                        Divider()
                        if model.isLoading && model.tasks.isEmpty {
                            Spacer(); ProgressView(); Spacer()
                        } else if model.tasks.isEmpty, let err = model.errorText {
                            Spacer(); ContentUnavailableView(err, systemImage: "wifi.exclamationmark"); Spacer()
                        } else {
                            boardScroller
                        }
                    }
                }
            }
            // Único campo de busca do board agora — a coluna de filtros do
            // meio (`BoardFilterList`, que também escrevia em
            // `model.searchResults`) foi removida, então não existe mais o
            // risco de dois campos vivos escrevendo no mesmo
            // `searchResults` em silêncio (achado Important 1 da revisão da
            // Task 13). Sem dono concorrente, o gate condicional
            // (`SearchableWhenCompact`) não fazia mais sentido — `.searchable`
            // direto, sempre ativo, é o mesmo comportamento que o iPhone já
            // tinha (lá o gate já era sempre `true`).
            //
            // No iPad o `.searchable` some daqui: quem monta a busca é
            // `padSearchField`, na posição principal da barra. Ver o comentário
            // dele. O `.searchable` do iPhone vive no `body`, junto do
            // `NavigationStack` que só existe lá.
            .onChange(of: searchText) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { await model.search(q) }
                }
            }
            // ⌘← / ⌘→ movem o card aberto no inspector — mesmo caminho otimista
            // do arraste. `.focusSearch` agora é sempre tratado e sempre
            // consumido aqui: a `BoardView` é a única dona da busca (a coluna
            // de filtros do meio, que antes podia ser a outra dona, foi
            // removida) — não há mais ramo concorrente que possa deixar de
            // focar depois de consumir (o que travaria o próximo ⌘F idêntico,
            // já que `AppIntent` só dispara `.onChange` na transição).
            //
            // Observa `nav.intentEvent` (envelope com `seq`), não `nav.intent`
            // cru: ⌘←/⌘← seguidos sem consumo no meio mandam o MESMO
            // `AppIntent`, e sem o `seq` o `.onChange` ficaria mudo no
            // segundo envio (achado Critical da revisão final — ver
            // `NavigationState.IntentEvent`).
            .onChange(of: nav.intentEvent) { _, event in
                let intent = event.intent
                if intent == .focusSearch {
                    searchFieldFocused = true
                    nav.consume()
                    return
                }
                let offset: Int
                switch intent {
                case .moveCardLeft:  offset = -1
                case .moveCardRight: offset = 1
                case .reload:
                    Task { await model.load() }
                    nav.consume()
                    return
                default:
                    return
                }
                nav.consume()
                guard let task = selected,
                      let current = BoardColumn(rawValue: task.column),
                      let destination = BoardMoveLogic.adjacentColumn(from: current, offset: offset)
                else { return }
                Task { await model.drop(task, on: .column(destination)) }
            }
            // Sem título no iPad: a coluna do lado já diz "Board" e o espaço é
            // da busca. No iPhone o título fica onde sempre esteve.
            .navigationTitle(embedded ? "" : "Cutuque Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .principal) { padSearchField }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Recarregar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showArchive = true
                        } label: {
                            Label("Arquivo semanal", systemImage: "archivebox")
                        }
                        Button {
                            // Pergunta ONDE arquivar — precisa das opções antes.
                            Task { await model.loadCloseOptions(); showCloseWeekConfirm = true }
                        } label: {
                            Label("Fechar semana", systemImage: "calendar.badge.checkmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Mais ações")
                }
            }
            .alert(CloseWeekPrompt.title(model.closeOptions), isPresented: $showCloseWeekConfirm) {
                Button("Cancelar", role: .cancel) {}
                if let last = model.closeOptions?.last {
                    Button(CloseWeekPrompt.juntarLabel(last)) {
                        Task { await model.closeWeek(week: last.label) }
                    }
                    Button(CloseWeekPrompt.novaLabel(model.closeOptions!.current), role: .destructive) {
                        Task { await model.closeWeek(week: model.closeOptions!.current.label) }
                    }
                } else {
                    Button("Fechar semana", role: .destructive) { Task { await model.closeWeek() } }
                }
            } message: {
                Text(CloseWeekPrompt.message(model.closeOptions))
            }
            .inspector(isPresented: Binding(get: { selected != nil },
                                            set: { if !$0 { selected = nil } })) {
                if let task = selected {
                    BoardTaskDetailView(task: task, model: model,
                                        readOnly: task.archived == true,
                                        onClose: { selected = nil })
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                } else {
                    // O inspector precisa de conteúdo mesmo fechado.
                    Color.clear
                }
            }
            .sheet(isPresented: $showArchive) {
                ArchiveView()
            }
            // Board "ao vivo": recarrega ao aparecer e a cada 12s, refletindo o que os
            // agentes fazem sem precisar de refresh manual.
            .task {
                while !Task.isCancelled {
                    await model.load()
                    try? await Task.sleep(for: .seconds(12))
                }
            }
    }

    /// No iPhone (e no iPad em Slide Over/Split View no mínimo) as colunas
    /// paginam no swipe (~86% cada, uma coluna por vez, com "encaixe"). No
    /// iPad largo elas dividem a largura disponível proporcionalmente — mas
    /// o piso de `BoardLayout.minColumnWidth` (260 pt) quase sempre entra em
    /// jogo nos tamanhos reais de tela: 5 colunas pedem `5×260 + 6×12 =
    /// 1372 pt`, 6 (com Encalhadas) pedem `1644 pt`, e nem o 13" em paisagem
    /// (1366 pt) cobre isso. Na prática o board sempre rola na horizontal
    /// pra ver todas as colunas no iPad também — só sem o "encaixe" de
    /// paginação, que atrapalharia o arraste de card.
    private var boardScroller: some View {
        GeometryReader { geo in
            // Largura MEDIDA, não idiom: em Slide Over ou Split View no
            // mínimo o idiom continua `.pad`, mas `geo.size.width` cai abaixo
            // dos 700 pt — as colunas precisam voltar a paginar como no
            // iPhone (achado da revisão da Task 16; `isRegular = isPad`
            // ignorava a largura que este próprio `GeometryReader` já mede).
            let isRegular = BoardLayout.isRegularWidth(idiom: idiom, measuredWidth: geo.size.width)
            let visibleColumns = BoardColumn.allCases.count + (model.encalhadas.isEmpty ? 0 : 1)
            let colWidth = BoardLayout.columnWidth(available: geo.size.width,
                                                   columns: visibleColumns,
                                                   isRegular: isRegular)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if !model.encalhadas.isEmpty {
                        BoardColumnCard(title: "Encalhadas", count: model.encalhadas.count,
                                        alert: true, tasks: model.encalhadas, width: colWidth,
                                        target: .encalhadas,
                                        onDrop: { id in
                                            guard let t = model.task(id: id) else { return }
                                            Task { await model.drop(t, on: .encalhadas) }
                                        }) { selected = $0 }
                    }
                    ForEach(BoardColumn.allCases) { column in
                        let items = model.inColumn(column)
                        BoardColumnCard(title: column.label, count: items.count,
                                        alert: false, tasks: items, width: colWidth,
                                        target: .column(column),
                                        onDrop: { id in
                                            guard let t = model.task(id: id) else { return }
                                            Task { await model.drop(t, on: .column(column)) }
                                        }) { selected = $0 }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            // Paginação só no compacto: no iPad as colunas já cabem juntas e o
            // "encaixe" por coluna atrapalharia o arraste de card.
            .modifier(PagingWhenCompact(enabled: !isRegular))
            .refreshable { await model.load() }
        }
    }

    // Resultados da busca (título + descrição + comentários; ativos e arquivados).
    private var searchResultsView: some View {
        Group {
            if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    Section("\(model.searchResults.count) resultado(s)") {
                        ForEach(model.searchResults) { t in
                            Button { selected = t } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if t.archived == true {
                                        Text("ARQUIVADO").font(.caption2).fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                    }
                                    BoardCardRow(task: t)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Barra de filtros

struct FilterBar: View {
    @ObservedObject var model: BoardModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterMenu(label: "Ambiente", selection: $model.filterGroup, options: model.groups)
                FilterMenu(label: "Tipo", selection: $model.filterType, options: model.types)
                FilterMenu(label: "Sessão", selection: $model.filterSession, options: model.sessions)
                if model.hasActiveFilter {
                    Button {
                        model.filterGroup = "all"; model.filterType = "all"; model.filterSession = "all"
                    } label: {
                        Label("Limpar", systemImage: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

struct FilterMenu: View {
    let label: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            Button { selection = "all" } label: {
                if selection == "all" { Label("Todos", systemImage: "checkmark") } else { Text("Todos") }
            }
            ForEach(options, id: \.self) { opt in
                Button { selection = opt } label: {
                    if selection == opt { Label(opt, systemImage: "checkmark") } else { Text(opt) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection == "all" ? label : "\(label): \(selection)")
                    .font(.caption).fontWeight(.medium).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(selection == "all" ? Color.secondary : Color.accentColor)
            .background(
                Capsule().fill(selection == "all" ? Color(.secondarySystemBackground)
                               : Color.accentColor.opacity(0.14))
            )
            .overlay(Capsule().stroke(selection == "all" ? Color(.separator).opacity(0.5)
                                      : Color.accentColor.opacity(0.5), lineWidth: 1))
        }
    }
}

// MARK: - Coluna (estilo Trello)

private struct BoardColumnCard: View {
    let title: String
    let count: Int
    let alert: Bool
    let tasks: [BoardTask]
    let width: CGFloat
    let target: BoardDropTarget
    let onDrop: (String) -> Void
    let onTap: (BoardTask) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if alert { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                Text(title.uppercased()).font(.caption).fontWeight(.bold).kerning(0.5)
                    .foregroundStyle(alert ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer()
                Text("\(count)").font(.caption).fontWeight(.semibold)
                    .foregroundStyle(alert ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if tasks.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "tray").font(.title3).foregroundStyle(.tertiary)
                            Text("nada por aqui").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                .foregroundStyle(Color(.separator).opacity(0.5))
                        )
                        .padding(.top, 4)
                    } else {
                        ForEach(tasks) { task in
                            BoardCardRow(task: task).onTapGesture { onTap(task) }
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(alert ? Color.red.opacity(0.06) : Color(.secondarySystemBackground).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(alert ? Color.red.opacity(0.45) : Color(.separator).opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            onDrop(id)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor, lineWidth: isTargeted ? 2.5 : 0)
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

// MARK: - Card (sem barra lateral; degradê neutro, só a tag colorida)

struct BoardCardRow: View {
    let task: BoardTask

    var body: some View {
        let typeColor = AgentTypeColor.color(for: task.type)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if task.isEncalhada {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
                Text(task.title).font(.subheadline).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let type = task.type, !type.isEmpty {
                    TagChip(text: type.uppercased(), color: typeColor, filled: true)
                }
                TagChip(text: task.group, color: GroupColor.color(for: task.group), filled: true)
                TagChip(text: task.session, color: .secondary, filled: false)
            }
            HStack(spacing: 12) {
                if let updated = task.updatedAt {
                    Label(Self.rel.localizedString(for: updated, relativeTo: Date()), systemImage: "clock")
                }
                if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "bubble.left") }
            }
            .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Encalhado: fundo chapado (sem degradê). Demais: degradê neutro.
            if task.isEncalhada {
                Color(.secondarySystemBackground)
            } else {
                LinearGradient(colors: [Color(.tertiarySystemBackground), Color(.secondarySystemBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            task.isEncalhada ? Color.red.opacity(0.5) : Color(.separator).opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        // Card arquivado é só leitura — não arrasta.
        .modifier(DraggableCard(id: task.id, enabled: task.archived != true))
    }

    static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()
}

/// Chip de tag (tipo/grupo/sessão).
struct TagChip: View {
    let text: String
    let color: Color
    let filled: Bool
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(filled ? .semibold : .regular)
            .foregroundStyle(filled ? color : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(filled ? color.opacity(0.16) : Color(.tertiarySystemBackground))
            .overlay(Capsule().stroke(filled ? color.opacity(0.4) : Color(.separator).opacity(0.4), lineWidth: 1))
            .clipShape(Capsule())
            .lineLimit(1)
    }
}

/// Renderiza o texto de um comentário com @menções em negrito + cor (igual ao web).
func mentionAttributed(_ text: String) -> AttributedString {
    var attr = AttributedString(text)
    guard let re = try? NSRegularExpression(pattern: "@[\\w.\\-]+") else { return attr }
    let ns = text as NSString
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let r = Range(m.range, in: text), let ar = Range(r, in: attr) else { continue }
        attr[ar].font = .callout.bold()
        attr[ar].foregroundColor = Color(red: 0.18, green: 0.50, blue: 0.98)
    }
    return attr
}

// MARK: - Detalhe do card (mover / encalhada / comentar / apagar)

struct BoardTaskDetailView: View {
    let task: BoardTask
    @ObservedObject var model: BoardModel
    var readOnly: Bool = false   // cards arquivados: só leitura (sem mover/apagar/comentar)
    /// Quando não-nil, fechar é responsabilidade de quem apresentou (inspector).
    /// Nil = sheet, e o `dismiss` do ambiente resolve, como sempre.
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var newComment = ""
    @FocusState private var commentFocused: Bool

    private var live: BoardTask { model.tasks.first { $0.id == task.id } ?? task }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Cabeçalho com título e ✕, DENTRO do conteúdo — não numa toolbar.
    ///
    /// Existe porque o `.inspector` do iPadOS não renderiza a barra de
    /// navegação do `NavigationStack` que ele apresenta: o botão "Fechar" de
    /// um `.toolbar` ali é montado e simplesmente não chega à tela.
    /// Verificado no simulador do iPad — o card abria sem título, sem ✕ e sem
    /// gesto de saída, e não havia como fechá-lo. No iPhone o mesmo detalhe é
    /// um sheet, a barra aparece e o "Fechar" sempre funcionou; por isso o
    /// furo passou despercebido até a Vanessa testar no iPad.
    ///
    /// Só entra quando `onClose != nil`, que são os dois casos iPad: o
    /// inspector do board e o `ArchivedTaskPane` na coluna de detalhe do
    /// Arquivo (ali o "Fechar" da toolbar chamava `dismiss()`, que numa coluna
    /// de split view não tem o que dispensar — o botão era morto). O sheet do
    /// arquivo semanal, no iPhone, passa `nil` e fica como sempre foi.
    private var inspectorHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(live.title)
                .font(.headline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fechar o card")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// `onClose != nil` é exatamente o caso iPad — inspector do board ou
    /// coluna de detalhe do Arquivo. Nos dois a barra de um `NavigationStack`
    /// aninhado é engolida (ver `inspectorHeader`), então ele não entra: seria
    /// uma faixa vazia no topo do card, e o "Fechar" dela nunca chegaria à
    /// tela. Quem fecha é o ✕ do `inspectorHeader`. No iPhone, sheet e
    /// `NavigationStack` de sempre.
    var body: some View {
        if onClose != nil {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle(live.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { close() } }
                    }
            }
        }
    }

    @ViewBuilder private var content: some View {
            VStack(spacing: 0) {
                if onClose != nil {
                    inspectorHeader
                    Divider()
                }
                detailList
            }
            .alert("Apagar card?", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Apagar", role: .destructive) { Task { await model.delete(live); close() } }
            } message: {
                Text("\"\(live.title)\" será apagado. Esta ação não pode ser desfeita.")
            }
    }

    private var detailList: some View {
            List {
                Section {
                    HStack(spacing: 6) {
                        if let type = live.type, !type.isEmpty {
                            TagChip(text: type.uppercased(), color: AgentTypeColor.color(for: type), filled: true)
                        }
                        TagChip(text: live.group, color: GroupColor.color(for: live.group), filled: true)
                        TagChip(text: live.session, color: .secondary, filled: false)
                    }
                    if let role = live.role, !role.isEmpty { LabeledContent("Quem", value: role) }
                    LabeledContent("Coluna", value: BoardColumn(rawValue: live.column)?.label ?? live.column)
                    if let desc = live.description, !desc.isEmpty {
                        Text(desc).font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !readOnly {
                    Section("Mover para") {
                        ForEach(BoardColumn.allCases) { column in
                            let isCurrent = live.column == column.rawValue && !live.isEncalhada
                            Button { Task { await model.move(live, to: column); close() } } label: {
                                HStack {
                                    Text(column.label)
                                    Spacer()
                                    if isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .disabled(isCurrent)
                        }
                        Button { Task { await model.markEncalhada(live); close() } } label: {
                            Label("Marcar como encalhada", systemImage: "exclamationmark.triangle")
                        }
                        .tint(.red).disabled(live.isEncalhada)
                    }
                }

                Section("Linha do tempo") {
                    timelineRow("Criado", live.createdAt)
                    timelineRow("Início", live.startedAt)
                    timelineRow("Revisão", live.reviewedAt)
                    timelineRow("Fim", live.endedAt)
                }

                if let acts = live.activity, !acts.isEmpty {
                    Section("Atividade") {
                        ForEach(acts.reversed()) { a in
                            HStack(alignment: .firstTextBaseline) {
                                Text(a.actor).fontWeight(.semibold) + Text(" \(a.action)").foregroundColor(.secondary)
                                Spacer()
                                if let at = a.at {
                                    Text(BoardCardRow.rel.localizedString(for: at, relativeTo: Date()))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }

                Section("Comentários (\(live.commentCount))") {
                    if let comments = live.comments, !comments.isEmpty {
                        ForEach(comments) { c in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.author).font(.caption).fontWeight(.semibold)
                                Text(mentionAttributed(c.text)).font(.callout)
                            }
                        }
                    } else {
                        Text("Nenhum comentário ainda.").font(.callout).foregroundStyle(.secondary)
                    }
                    if !readOnly {
                        HStack {
                            TextField("Adicionar comentário…", text: $newComment, axis: .vertical)
                                .focused($commentFocused)
                            Button {
                                let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                newComment = ""; commentFocused = false
                                Task { await model.comment(live, text: text) }
                            } label: {
                                Image(systemName: "paperplane.fill")
                            }
                            .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                if !readOnly {
                    Section {
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Apagar card", systemImage: "trash")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private func timelineRow(_ label: String, _ date: Date?) -> some View {
        LabeledContent(label, value: date.map { Self.dt.string(from: $0) } ?? "—")
    }

    static let dt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Arquivo semanal (mês > semana, pt-BR)

struct ArchiveView: View {
    var embedded: Bool = false
    var selection: Binding<BoardTask?>?
    @Environment(\.dismiss) private var dismiss
    @State private var weeks: [ArchivedWeek] = []
    @State private var loading = true
    @State private var selected: BoardTask?
    @StateObject private var roModel = BoardModel()   // vazio, só p/ o detalhe read-only
    private let api = APIClient()

    var body: some View {
        Group {
            if embedded { archiveList } else { NavigationStack { archiveList } }
        }
        .task {
            loading = true
            weeks = (try? await api.boardArchive()) ?? []
            loading = false
        }
    }

    @ViewBuilder private var archiveList: some View {
        Group {
            if loading {
                ProgressView()
            } else if weeks.isEmpty {
                ContentUnavailableView("Nada arquivado ainda", systemImage: "archivebox",
                    description: Text("Os concluídos vêm pra cá no fechamento da semana."))
            } else {
                List {
                    ForEach(months, id: \.key) { m in
                        Section(m.label) {
                            ForEach(m.weeks) { wk in
                                DisclosureGroup {
                                    ForEach(wk.tasks) { t in
                                        Button {
                                            if let selection { selection.wrappedValue = t }
                                            else { selected = t }
                                        } label: { BoardCardRow(task: t) }
                                            .buttonStyle(.plain)
                                    }
                                } label: {
                                    HStack {
                                        Text(Self.range(wk)).font(.subheadline).fontWeight(.medium)
                                        Spacer()
                                        Text("\(wk.tasks.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Arquivo semanal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
        }
        .sheet(item: embedded ? .constant(nil) : $selected) { t in
            BoardTaskDetailView(task: t, model: roModel, readOnly: true)
        }
    }

    private struct Month { let key: String; let label: String; let weeks: [ArchivedWeek] }
    private var months: [Month] {
        var order: [String] = []
        var map: [String: [ArchivedWeek]] = [:]
        for wk in weeks {
            let k = Self.monthKey(wk.start)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(wk)
        }
        return order.map { Month(key: $0, label: Self.monthLabel(map[$0]!.first!.start), weeks: map[$0]!) }
    }

    // ---- datas pt-BR (mês = quinta-feira da semana ISO) ----
    private static func parse(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    private static func thursday(_ start: String) -> Date {
        Calendar.current.date(byAdding: .day, value: 3, to: parse(start)) ?? parse(start)
    }
    private static func monthKey(_ start: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: thursday(start))
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
    private static func monthLabel(_ start: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "LLLL 'de' yyyy"
        let s = f.string(from: thursday(start))
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    private static func range(_ wk: ArchivedWeek) -> String {
        WeekRangeFormat.text(start: wk.start, end: wk.end)
    }
}

/// `.draggable` muda o tipo da view, então não dá pra aplicá-lo condicionalmente
/// inline. Card arquivado passa direto, sem virar fonte de arraste.
private struct DraggableCard: ViewModifier {
    let id: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}

/// `.scrollTargetBehavior` não é condicionável inline (os behaviors são tipos
/// concretos distintos); este modifier resolve com um `if` de verdade.
private struct PagingWhenCompact: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.scrollTargetBehavior(.viewAligned) } else { content }
    }
}

/// `.searchFocused(_:)` só existe a partir do iOS 18 (checado contra o SDK: a
/// sobrecarga de `FocusState<Bool>.Binding` está marcada `@available(iOS
/// 18.0, ...)`), mas o `deploymentTarget` deste projeto é 17.0
/// (`project.yml`). Em iOS 17 este modifier vira no-op: o `⌘F` ainda consome
/// o intent certo — o que resolve o travamento da rodada 3 — só não empurra o
/// teclado sozinho pro campo. Em iOS 18+ ele foca de verdade.
private struct SearchFocusWhenAvailable: ViewModifier {
    var focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

