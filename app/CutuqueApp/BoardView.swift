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
    func closeWeek() async {
        do { try await api.closeWeek(); await load() }
        catch { errorText = "Falha ao fechar a semana." }
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
    // Injetado pelo app: a coluna de filtros (iPad) precisa do MESMO modelo.
    @EnvironmentObject private var model: BoardModel
    @EnvironmentObject private var nav: NavigationState
    @State private var showCloseWeekConfirm = false
    @State private var showArchive = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    // Foco do campo de busca própria, pra atender `.focusSearch` quando ESTA
    // view é a dona (ver `showsOwnFilterAndSearch`) — rodada 3 da revisão da
    // Task 16: antes disto o `⌘F` não tinha como focar nada aqui.
    @FocusState private var searchFieldFocused: Bool
    // "Estou estreito AGORA?" — muda em runtime (Slide Over, Split View no
    // mínimo, rotação). Nunca decide "sou iPad?" (isso é `isPad`, por idiom).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Idiom: nunca muda em runtime (mesmo valor que escolhe a raiz do app em
    // `CutuqueApp.swift`). Lido uma vez aqui e reaproveitado por `isPad` e
    // pelo `boardScroller` — nada de ler `UIDevice.current.userInterfaceIdiom`
    // duas vezes soltas pela view.
    private var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }

    /// iPad de verdade — NÃO `horizontalSizeClass == .regular` (achado
    /// Important 2 da revisão: iPhone Plus/Pro Max em paisagem também reporta
    /// `.regular`, e isso fazia o `BoardView` dentro do `RootTabView`, raiz do
    /// iPhone, esconder a FilterBar sem `BoardFilterList` pra substituí-la,
    /// esconder os resultados de busca e desligar a paginação por swipe — uma
    /// regressão no iPhone, proibida pela restrição global do plano). Mesmo
    /// idiom que escolhe a raiz do app em `CutuqueApp.swift`.
    private var isPad: Bool { BoardLayout.isPad(idiom) }

    /// O `BoardFilterList` (coluna do meio, dono dos filtros e da busca) some
    /// de vista em três situações independentes — Slide Over/Split View no
    /// mínimo (`horizontalSizeClass == .compact`), OU a regra dos 700 pt
    /// escondendo sidebar+conteúdo (`nav.columnVisibility == .detailOnly`,
    /// que dispara até em tela cheia `.regular`: um iPad de 11" em retrato
    /// normal já tem coluna de detalhe abaixo de 700 pt — achado da rodada 2
    /// da revisão da Task 16, reabrindo por um gatilho mais comum que o
    /// Slide Over que motivou a task). Em qualquer uma delas, e mesmo no
    /// iPad, o `BoardView` precisa da própria FilterBar/busca, como sempre
    /// foi no iPhone. No iPhone `isPad` é sempre falso, então isto é sempre
    /// `true` — comportamento preservado.
    private var showsOwnFilterAndSearch: Bool {
        BoardLayout.showsOwnFilterAndSearch(isPad: isPad,
                                             horizontalSizeClassIsCompact: horizontalSizeClass == .compact,
                                             columnVisibilityIsDetailOnly: nav.columnVisibility == .detailOnly)
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // No iPad a busca da coluna do meio (BoardFilterList) também precisa
    // conseguir abrir o card — por isso o estado mora no NavigationState
    // compartilhado, não num @State local desta view.
    private var selected: BoardTask? {
        get { nav.boardSelection }
        nonmutating set { nav.boardSelection = newValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && showsOwnFilterAndSearch {
                    // Compacto (iPhone, ou iPad em Slide Over/Split View no
                    // mínimo): a busca ainda toma a tela, como sempre foi.
                    searchResultsView
                } else {
                    VStack(spacing: 0) {
                        // No iPad largo os filtros moram na coluna do meio
                        // (`BoardFilterList`); em Slide Over ela saiu de
                        // vista, então a FilterBar própria volta.
                        if showsOwnFilterAndSearch {
                            FilterBar(model: model)
                            Divider()
                        }
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
            // No iPad LARGO a busca já mora inteira na coluna do meio
            // (`BoardFilterList`) — manter esta aqui também deixaria DOIS
            // campos vivos escrevendo em `model.searchResults` ao mesmo
            // tempo, o de trás sobrescrevendo o da frente em silêncio, sem
            // nunca aparecer (achado Important 1 da revisão). No iPhone a
            // busca continua exatamente como sempre foi. No iPad em Slide
            // Over/Split View no mínimo o `BoardFilterList` colapsou pra
            // trás na pilha — sem esta busca o board ficaria sem NENHUMA
            // forma de buscar (achado da revisão da Task 16).
            .modifier(SearchableWhenCompact(enabled: showsOwnFilterAndSearch, text: $searchText))
            .modifier(SearchFocusWhenAvailable(focused: $searchFieldFocused))
            .onChange(of: searchText) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { await model.search(q) }
                }
            }
            // ⌘← / ⌘→ movem o card aberto no inspector — mesmo caminho otimista
            // do arraste. `.focusSearch` só é tratado aqui quando ESTA view é a
            // dona da busca (`showsOwnFilterAndSearch`); do contrário quem foca
            // é o `BoardFilterList` (coluna do meio) — os dois ramos usam o
            // MESMO predicado, um negado do outro, então exatamente um trata e
            // consome (achado da rodada 3 da revisão: consumir sem tratar
            // travava o `⌘F` porque `AppIntent` só dispara `.onChange` na
            // transição, e um `default: nav.consume()` engolia o intent sem
            // ninguém focar o campo visível).
            //
            // Observa `nav.intentEvent` (envelope com `seq`), não `nav.intent`
            // cru: ⌘←/⌘← seguidos sem consumo no meio mandam o MESMO
            // `AppIntent`, e sem o `seq` o `.onChange` ficaria mudo no
            // segundo envio (achado Critical da revisão final — ver
            // `NavigationState.IntentEvent`).
            .onChange(of: nav.intentEvent) { _, event in
                let intent = event.intent
                if intent == .focusSearch {
                    guard showsOwnFilterAndSearch else { return }
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
            .navigationTitle("Cutuque Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                            showCloseWeekConfirm = true
                        } label: {
                            Label("Fechar semana", systemImage: "calendar.badge.checkmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Mais ações")
                }
            }
            .alert("Fechar a semana agora?", isPresented: $showCloseWeekConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Fechar semana", role: .destructive) { Task { await model.closeWeek() } }
            } message: {
                Text("Os concluídos serão arquivados e saem do board; to-dos antigos não iniciados viram encalhados. Normalmente acontece sozinho no domingo 23:59.")
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

    var body: some View {
        NavigationStack {
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
            .navigationTitle(live.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { close() } } }
            .alert("Apagar card?", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Apagar", role: .destructive) { Task { await model.delete(live); close() } }
            } message: {
                Text("\"\(live.title)\" será apagado. Esta ação não pode ser desfeita.")
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
        let s = parse(wk.start), e = parse(wk.end)
        let day = DateFormatter(); day.locale = Locale(identifier: "pt_BR"); day.dateFormat = "d"
        let mon = DateFormatter(); mon.locale = Locale(identifier: "pt_BR"); mon.dateFormat = "MMM"
        let sMon = mon.string(from: s).replacingOccurrences(of: ".", with: "")
        let eMon = mon.string(from: e).replacingOccurrences(of: ".", with: "")
        let cal = Calendar.current
        if cal.component(.month, from: s) == cal.component(.month, from: e) {
            return "\(day.string(from: s)) – \(day.string(from: e)) de \(eMon)"
        }
        return "\(day.string(from: s)) de \(sMon) – \(day.string(from: e)) de \(eMon)"
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

/// Mesmo precedente do `PagingWhenCompact`: `.searchable` muda o tipo
/// concreto da view, então não dá pra condicionar inline com ternário. No
/// iPad este modifier some por completo — a busca da coluna de detalhe não
/// existe mais, só a da coluna do meio (`BoardFilterList`) fica viva. É a
/// correção do achado Important 1 (busca dupla no iPad escrevendo, as duas,
/// no mesmo `model.searchResults`).
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

private struct SearchableWhenCompact: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: "Buscar título, descrição, comentários…")
        } else {
            content
        }
    }
}
