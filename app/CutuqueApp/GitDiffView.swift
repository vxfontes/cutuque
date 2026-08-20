import SwiftUI

/// Painel nativo de alterações Git de uma máquina.
///
/// A view permanece montada junto com Terminal e Arquivos no iPad, mas o
/// request só nasce quando `isActive` é verdadeiro. Assim trocar de painel não
/// derruba o PTY nem dispara uma consulta por aba que a usuária ainda não viu.
struct GitDiffView: View {
    let machine: String
    let isActive: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage private var savedDirectory: String

    @State private var directory: String
    @State private var draftDirectory: String
    @State private var reloadID = 0
    @State private var snapshot: GitDiff?
    @State private var loading = false
    @State private var error: String?

    private let api = APIClient()

    init(machine: String, isActive: Bool = true) {
        self.machine = machine
        self.isActive = isActive

        let key = Self.storageKey(machine: machine)
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        _savedDirectory = AppStorage(wrappedValue: stored, key)
        _directory = State(initialValue: stored)
        _draftDirectory = State(initialValue: stored)
    }

    private var isPadLayout: Bool { horizontalSizeClass == .regular }

    /// Uma nova ativação do painel muda o id da task e atualiza o retrato.
    /// Digitar no campo não muda `directory` até confirmar, evitando um
    /// request a cada caractere.
    private var loadID: String {
        "\(isActive)-\(directory)-\(reloadID)"
    }

    static func storageKey(machine: String) -> String {
        "cutuque.machineGitDiffDir.\(machine)"
    }

    var body: some View {
        VStack(spacing: 0) {
            directoryBar

            Group {
                if let error {
                    errorContent(error)
                } else if let snapshot {
                    snapshotContent(snapshot)
                } else if directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyDirectoryContent
                } else {
                    loadingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: loadID) {
            await loadIfActive()
        }
    }

    private var directoryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            TextField("Pasta do repositório", text: $draftDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: isPadLayout ? 15 : 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submitDirectory)

            Button(action: submitDirectory) {
                Image(systemName: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!isActive || draftDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Carregar diff")

            Button {
                reloadID += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!isActive || directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Atualizar diff")
        }
        .padding(.horizontal, isPadLayout ? 20 : 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyDirectoryContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: isPadLayout ? 34 : 28))
                .foregroundStyle(.secondary)
            Text("Escolha uma pasta Git")
                .font(.headline)
            Text("Digite o caminho da pasta na máquina para ver as alterações.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Lendo o estado do repositório…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Não foi possível carregar o diff")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Tentar de novo") {
                reloadID += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isActive)
        }
        .padding()
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: GitDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(snapshot)

            if snapshot.truncated {
                Label("O diff foi encurtado para caber na resposta.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, isPadLayout ? 20 : 12)
                    .padding(.vertical, 8)
            }

            if isPadLayout {
                iPadContent(snapshot)
            } else {
                iPhoneContent(snapshot)
            }
        }
    }

    private func summary(_ snapshot: GitDiff) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stateSymbol(snapshot.state))
                .foregroundStyle(stateColor(snapshot.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel(snapshot.state))
                    .font(.headline)
                Text(snapshot.root.isEmpty ? snapshot.dir : snapshot.root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !snapshot.files.isEmpty {
                Text("\(snapshot.files.count) arquivo\(snapshot.files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isPadLayout ? 20 : 12)
        .padding(.vertical, 10)
    }

    private func iPadContent(_ snapshot: GitDiff) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical) {
                fileChanges(snapshot.files)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(width: 250)

            Divider()

            diffContent(snapshot.diff)
                .padding(12)
        }
    }

    private func iPhoneContent(_ snapshot: GitDiff) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                fileChanges(snapshot.files)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()
                    .padding(.top, 4)

                diffContent(snapshot.diff)
                    .padding(12)
                    .frame(minHeight: 260)
            }
        }
    }

    private func fileChanges(_ files: [GitFileChange]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arquivos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if files.isEmpty {
                Text("Nenhum arquivo alterado")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(files, id: \.path) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fileStatus(file))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(fileStatusColor(file))
                            .frame(minWidth: 22, alignment: .leading)
                        Text(file.path)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func diffContent(_ diff: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diff")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if diff.isEmpty {
                Text("Nenhuma alteração para mostrar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(Ansi.attributed(diff,
                                         size: isPadLayout ? 13 : 11,
                                         defaultColor: .primary))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(minWidth: 0, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func submitDirectory() {
        let value = draftDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        directory = value
        savedDirectory = value
        snapshot = nil
        error = nil
        reloadID += 1
    }

    private func loadIfActive() async {
        guard isActive else { return }
        let requestedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedDirectory.isEmpty else { return }

        loading = true
        error = nil
        do {
            let loaded = try await api.gitDiff(machine: machine, dir: requestedDirectory)
            try Task.checkCancellation()
            guard isActive, directory.trimmingCharacters(in: .whitespacesAndNewlines) == requestedDirectory else {
                return
            }
            snapshot = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func fileStatus(_ file: GitFileChange) -> String {
        let value = file.worktree == "unchanged" ? file.index : file.worktree
        switch value {
        case "added": return "A"
        case "deleted": return "D"
        case "renamed": return "R"
        case "copied": return "C"
        case "conflicted": return "!"
        case "modified": return "M"
        case "untracked": return "?"
        default: return "·"
        }
    }

    private func fileStatusColor(_ file: GitFileChange) -> Color {
        switch fileStatus(file) {
        case "A", "?": return .green
        case "D": return .red
        case "!": return .orange
        case "R", "C": return .blue
        default: return .secondary
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "clean": return "Repositório limpo"
        case "not_a_repository": return "Não é um repositório Git"
        case "changes": return "Alterações locais"
        default: return state.isEmpty ? "Estado desconhecido" : state
        }
    }

    private func stateSymbol(_ state: String) -> String {
        switch state {
        case "clean": return "checkmark.circle"
        case "not_a_repository": return "questionmark.folder"
        case "changes": return "circle.lefthalf.filled"
        default: return "questionmark.circle"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "clean": return .green
        case "not_a_repository": return .secondary
        case "changes": return .orange
        default: return .secondary
        }
    }
}
