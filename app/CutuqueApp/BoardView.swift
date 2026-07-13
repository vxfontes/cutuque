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
    @StateObject private var model = BoardModel()
    @State private var selected: BoardTask?
    @State private var showCloseWeekConfirm = false
    @State private var showArchive = false

    var body: some View {
        NavigationStack {
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
            .sheet(item: $selected) { task in
                BoardTaskDetailView(task: task, model: model)
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

    // Colunas lado a lado, cada uma ~85% da largura, com paginação (swipe estilo Trello).
    private var boardScroller: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width * 0.86
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if !model.encalhadas.isEmpty {
                        BoardColumnCard(title: "Encalhadas", count: model.encalhadas.count,
                                        alert: true, tasks: model.encalhadas, width: colWidth) { selected = $0 }
                    }
                    ForEach(BoardColumn.allCases) { column in
                        let items = model.inColumn(column)
                        BoardColumnCard(title: column.label, count: items.count,
                                        alert: false, tasks: items, width: colWidth) { selected = $0 }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .refreshable { await model.load() }
        }
    }
}

// MARK: - Barra de filtros

private struct FilterBar: View {
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

private struct FilterMenu: View {
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
    let onTap: (BoardTask) -> Void

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

// MARK: - Detalhe do card (mover / encalhada / comentar / apagar)

struct BoardTaskDetailView: View {
    let task: BoardTask
    @ObservedObject var model: BoardModel
    var readOnly: Bool = false   // cards arquivados: só leitura (sem mover/apagar/comentar)
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var newComment = ""
    @FocusState private var commentFocused: Bool

    private var live: BoardTask { model.tasks.first { $0.id == task.id } ?? task }

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
                            Button { Task { await model.move(live, to: column); dismiss() } } label: {
                                HStack {
                                    Text(column.label)
                                    Spacer()
                                    if isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .disabled(isCurrent)
                        }
                        Button { Task { await model.markEncalhada(live); dismiss() } } label: {
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
                                Text(c.text).font(.callout)
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .alert("Apagar card?", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Apagar", role: .destructive) { Task { await model.delete(live); dismiss() } }
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
    @Environment(\.dismiss) private var dismiss
    @State private var weeks: [ArchivedWeek] = []
    @State private var loading = true
    @State private var selected: BoardTask?
    @StateObject private var roModel = BoardModel()   // vazio, só p/ o detalhe read-only
    private let api = APIClient()

    var body: some View {
        NavigationStack {
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
                                            Button { selected = t } label: { BoardCardRow(task: t) }
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } } }
            .sheet(item: $selected) { t in
                BoardTaskDetailView(task: t, model: roModel, readOnly: true)
            }
        }
        .task {
            loading = true
            weeks = (try? await api.boardArchive()) ?? []
            loading = false
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
