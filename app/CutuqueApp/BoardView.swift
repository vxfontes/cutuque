import SwiftUI

// MARK: - ViewModel

/// Estado do Cutuque Board no app: carrega os cards do hub e executa as ações
/// (mover, marcar encalhada, apagar). Sem WebSocket — carrega no aparecer e
/// no pull-to-refresh, além de re-carregar após cada ação.
@MainActor
final class BoardModel: ObservableObject {
    @Published var tasks: [BoardTask] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private let api = APIClient()

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await api.boardTasks()
            errorText = nil
        } catch {
            errorText = "Não consegui carregar o board."
        }
    }

    func move(_ task: BoardTask, to column: BoardColumn) async {
        do { try await api.moveBoardTask(id: task.id, column: column.rawValue); await load() }
        catch { errorText = "Falha ao mover o card." }
    }

    func markEncalhada(_ task: BoardTask) async {
        do { try await api.setBoardEncalhada(id: task.id, true); await load() }
        catch { errorText = "Falha ao marcar como encalhada." }
    }

    func delete(_ task: BoardTask) async {
        do { try await api.deleteBoardTask(id: task.id); await load() }
        catch { errorText = "Falha ao apagar o card." }
    }

    // Agrupamentos (espelham o dashboard web).
    var encalhadas: [BoardTask] {
        tasks.filter { $0.isEncalhada }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
    func inColumn(_ column: BoardColumn) -> [BoardTask] {
        tasks.filter { $0.column == column.rawValue && !($0.isEncalhada && column == .aFazer) }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }
}

// MARK: - Board (lista por colunas, com scroll nativo)

struct BoardView: View {
    @StateObject private var model = BoardModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selected: BoardTask?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if !model.encalhadas.isEmpty {
                        BoardSectionView(title: "Encalhadas", count: model.encalhadas.count, alert: true) {
                            ForEach(model.encalhadas) { task in
                                BoardCardRow(task: task).onTapGesture { selected = task }
                            }
                        }
                    }
                    ForEach(BoardColumn.allCases) { column in
                        let items = model.inColumn(column)
                        BoardSectionView(title: column.label, count: items.count, alert: false) {
                            if items.isEmpty {
                                Text("—").font(.footnote).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
                            } else {
                                ForEach(items) { task in
                                    BoardCardRow(task: task).onTapGesture { selected = task }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Cutuque Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Recarregar")
                }
            }
            .refreshable { await model.load() }
            .overlay {
                if model.isLoading && model.tasks.isEmpty { ProgressView() }
                else if model.tasks.isEmpty, let err = model.errorText {
                    ContentUnavailableView(err, systemImage: "wifi.exclamationmark")
                }
            }
            .sheet(item: $selected) { task in
                BoardTaskDetailView(task: task, model: model)
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Seção (coluna) + card

/// Uma "coluna" do board renderizada como seção vertical (idiomático no iPhone).
private struct BoardSectionView<Content: View>: View {
    let title: String
    let count: Int
    let alert: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if alert { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                Text(title.uppercased())
                    .font(.caption).fontWeight(.bold).kerning(0.5)
                    .foregroundStyle(alert ? Color.red : .secondary)
                Spacer()
                Text("\(count)").font(.caption).fontWeight(.semibold)
                    .foregroundStyle(alert ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            }
            content
        }
        .padding(alert ? 12 : 0)
        .background {
            if alert {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.red.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.45), lineWidth: 1))
            }
        }
    }
}

/// Card de uma tarefa. Barra lateral na cor do tipo (ou vermelha se encalhada).
/// Encalhados ficam neutros — só a TAG do tipo mantém a cor (igual ao web).
struct BoardCardRow: View {
    let task: BoardTask

    var body: some View {
        let typeColor = AgentTypeColor.color(for: task.type)
        let accent = task.isEncalhada ? Color.red : typeColor
        HStack(spacing: 0) {
            Rectangle().fill(accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    if task.isEncalhada {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                    Text(task.title).font(.subheadline).fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if let type = task.type, !type.isEmpty {
                        TagChip(text: type.uppercased(), color: typeColor, filled: true)
                    }
                    TagChip(text: task.group, color: .secondary, filled: false)
                    TagChip(text: task.session, color: .secondary, filled: false)
                }
                HStack(spacing: 12) {
                    if let updated = task.updatedAt {
                        Label(Self.rel.localizedString(for: updated, relativeTo: Date()), systemImage: "clock")
                    }
                    if task.commentCount > 0 {
                        Label("\(task.commentCount)", systemImage: "bubble.left")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(Color(.secondarySystemBackground))
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

// MARK: - Detalhe do card (com mover / marcar encalhada / apagar)

struct BoardTaskDetailView: View {
    let task: BoardTask
    @ObservedObject var model: BoardModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private var live: BoardTask { model.tasks.first { $0.id == task.id } ?? task }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 6) {
                        if let type = live.type, !type.isEmpty {
                            TagChip(text: type.uppercased(), color: AgentTypeColor.color(for: type), filled: true)
                        }
                        TagChip(text: live.group, color: .secondary, filled: false)
                        TagChip(text: live.session, color: .secondary, filled: false)
                    }
                    if let role = live.role, !role.isEmpty {
                        LabeledContent("Quem", value: role)
                    }
                    LabeledContent("Coluna", value: BoardColumn(rawValue: live.column)?.label ?? live.column)
                    if let desc = live.description, !desc.isEmpty {
                        Text(desc).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section("Mover para") {
                    ForEach(BoardColumn.allCases) { column in
                        let isCurrent = live.column == column.rawValue && !live.isEncalhada
                        Button {
                            Task { await model.move(live, to: column); dismiss() }
                        } label: {
                            HStack {
                                Text(column.label)
                                Spacer()
                                if isCurrent { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .disabled(isCurrent)
                    }
                    Button {
                        Task { await model.markEncalhada(live); dismiss() }
                    } label: {
                        Label("Marcar como encalhada", systemImage: "exclamationmark.triangle")
                    }
                    .tint(.red)
                    .disabled(live.isEncalhada)
                }

                Section("Linha do tempo") {
                    timelineRow("Criado", live.createdAt)
                    timelineRow("Início", live.startedAt)
                    timelineRow("Revisão", live.reviewedAt)
                    timelineRow("Fim", live.endedAt)
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
                }

                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Apagar card", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(live.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
            .alert("Apagar card?", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Apagar", role: .destructive) {
                    Task { await model.delete(live); dismiss() }
                }
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
