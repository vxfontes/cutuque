import SwiftUI

// MARK: - Temas do terminal

/// Esquemas de cor do espelho de terminal (preferência local da usuária). As
/// cores do claude (ANSI) entram por cima; o tema define o fundo e a cor base.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case dark, midnight, light, phosphor, amber
    case dracula, nord, gruvbox, oneDark, tokyoNight, solarizedDark, solarizedLight, paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark:           return "Escuro"
        case .midnight:       return "Meia-noite"
        case .light:          return "Claro"
        case .phosphor:       return "Verde fósforo"
        case .amber:          return "Âmbar"
        case .dracula:        return "Dracula"
        case .nord:           return "Nord"
        case .gruvbox:        return "Gruvbox"
        case .oneDark:        return "One Dark"
        case .tokyoNight:     return "Tokyo Night"
        case .solarizedDark:  return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .paper:          return "Papel"
        }
    }

    var bg: Color {
        switch self {
        case .dark:           return Color(white: 0.08)
        case .midnight:       return Color(red: 0.05, green: 0.07, blue: 0.15)
        case .light:          return Color(white: 0.97)
        case .phosphor:       return .black
        case .amber:          return Color(red: 0.10, green: 0.07, blue: 0.02)
        case .dracula:        return Color(red: 0.16, green: 0.16, blue: 0.21)
        case .nord:           return Color(red: 0.18, green: 0.20, blue: 0.25)
        case .gruvbox:        return Color(red: 0.16, green: 0.16, blue: 0.14)
        case .oneDark:        return Color(red: 0.16, green: 0.18, blue: 0.20)
        case .tokyoNight:     return Color(red: 0.10, green: 0.11, blue: 0.18)
        case .solarizedDark:  return Color(red: 0.00, green: 0.17, blue: 0.21)
        case .solarizedLight: return Color(red: 0.99, green: 0.96, blue: 0.89)
        case .paper:          return Color(red: 0.96, green: 0.95, blue: 0.92)
        }
    }

    var fg: Color {
        switch self {
        case .dark:           return Color(white: 0.92)
        case .midnight:       return Color(red: 0.80, green: 0.85, blue: 1.0)
        case .light:          return Color(white: 0.10)
        case .phosphor:       return Color(red: 0.30, green: 1.0, blue: 0.40)
        case .amber:          return Color(red: 1.0, green: 0.75, blue: 0.30)
        case .dracula:        return Color(red: 0.95, green: 0.95, blue: 0.96)
        case .nord:           return Color(red: 0.85, green: 0.88, blue: 0.93)
        case .gruvbox:        return Color(red: 0.92, green: 0.86, blue: 0.70)
        case .oneDark:        return Color(red: 0.67, green: 0.71, blue: 0.76)
        case .tokyoNight:     return Color(red: 0.79, green: 0.83, blue: 0.96)
        case .solarizedDark:  return Color(red: 0.51, green: 0.58, blue: 0.59)
        case .solarizedLight: return Color(red: 0.40, green: 0.48, blue: 0.51)
        case .paper:          return Color(red: 0.15, green: 0.15, blue: 0.17)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class TerminalMirrorModel: ObservableObject {
    let machine: String
    let target: String

    @Published var screen: String = ""
    @Published var sending = false
    @Published var errorMessage: String?
    /// Vira true quando o pane foi encerrado com sucesso (a view fecha em cima disso).
    @Published var killed = false

    private let api = APIClient()
    private var pollTask: Task<Void, Never>?

    init(machine: String, target: String) {
        self.machine = machine
        self.target = target
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func resize(cols: Int, rows: Int) {
        Task { await api.tmuxResize(machine: machine, target: target, cols: cols, rows: rows) }
    }

    func restoreSize() {
        Task { await api.tmuxResize(machine: machine, target: target, cols: 0, rows: 0) }
    }

    /// Encerra o pane do tmux (kill-pane): fecha o Claude daquele terminal. Em
    /// sucesso, marca `killed` para a view fechar; para o poll antes.
    func kill() async {
        do {
            try await api.tmuxKill(machine: machine, target: target)
            stop()
            killed = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Só atualiza (e re-renderiza) quando a tela realmente muda — evita
    /// re-parsear ANSI à toa a cada poll.
    private func refresh() async {
        let s = await api.tmuxScreen(machine: machine, target: target)
        if !s.isEmpty && s != screen { screen = s }
    }

    /// Digita a mensagem no terminal ao vivo (send-keys + Enter).
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.tmuxSendKeys(machine: machine, target: target, text: trimmed)
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Envia uma tecla nomeada (Ctrl+C, setas, Esc, Enter, Tab…).
    func sendKey(_ key: String) async {
        do {
            try await api.tmuxKey(machine: machine, target: target, key: key)
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Espelho do terminal

/// Espelho ao vivo de um pane do tmux: mostra a tela (com cores reais do claude),
/// deixa digitar, mandar teclas especiais (Ctrl+C, setas p/ subagentes…), trocar
/// tema, e seguir/pausar o rolar pra ler histórico. É pensado pra ser empurrado
/// dentro de uma NavigationStack (ex.: a partir do LiveDetailView).
struct TerminalMirrorView: View {
    let machine: String
    let target: String
    let title: String

    @StateObject private var model: TerminalMirrorModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var confirmingKill = false
    @FocusState private var inputFocused: Bool
    @AppStorage("cutuque.terminalTheme") private var themeRaw = TerminalTheme.dark.rawValue
    private var theme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dark }

    // Tamanho da fonte, ajustável (A−/A+). Menor = mais colunas = a TUI do claude
    // renderiza mais larga (parecida com o PC); maior = mais legível.
    @AppStorage("cutuque.terminalFont") private var fontPtStored: Double = 10
    private var fontPt: CGFloat { CGFloat(fontPtStored) }
    private let fontMin = 5.0
    private let fontMax = 22.0

    init(machine: String, target: String, title: String) {
        self.machine = machine
        self.target = target
        self.title = title
        _model = StateObject(wrappedValue: TerminalMirrorModel(machine: machine, target: target))
    }

    var body: some View {
        GeometryReader { geo in
            // 0.62 ≈ largura/altura do SF Mono, com folga pra a linha do claude
            // NÃO re-quebrar no app (o que deixava o layout "zicado").
            let cols = max(30, Int((geo.size.width - 16) / (fontPt * 0.62)))
            // Reserva só o mínimo (barras) para dar o MÁXIMO de linhas ao pane:
            // fonte menor → muito mais linhas → o claude mostra mais da conversa
            // de uma vez (mais contexto), além do PageUp pra subir mais ainda.
            let rows = max(20, Int((geo.size.height - 120) / (fontPt * 1.28)))
            VStack(spacing: 0) {
                terminal
                keyBar
                inputBar
            }
            .task(id: "\(cols)x\(rows)") {
                model.resize(cols: cols, rows: rows)
                model.start()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { themeMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmingKill = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .tint(.red)
                .accessibilityLabel("Encerrar sessão do tmux")
            }
        }
        .onDisappear {
            model.stop()
            model.restoreSize()
        }
        // Encerrar é destrutivo: confirma antes. kill-pane fecha o Claude do pane.
        .confirmationDialog(
            "Encerrar esta sessão?",
            isPresented: $confirmingKill,
            titleVisibility: .visible
        ) {
            Button("Encerrar sessão", role: .destructive) {
                Task { await model.kill() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O Claude que roda neste terminal será fechado (kill-pane).")
        }
        // Encerrou com sucesso: fecha o espelho e volta.
        .onChange(of: model.killed) { _, killed in
            if killed { dismiss() }
        }
        .alert(
            "Não foi possível enviar",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in Button("OK", role: .cancel) {} } message: { Text($0) }
    }

    // MARK: Toolbar

    private var themeMenu: some View {
        Menu {
            Picker("Tema", selection: $themeRaw) {
                ForEach(TerminalTheme.allCases) { t in Text(t.label).tag(t.rawValue) }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
    }

    // MARK: Terminal

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: model.screen) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .task { // primeira rolagem ao abrir
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            // Rolar o HISTÓRICO da conversa do claude (a TUI usa tela alternada,
            // sem scrollback no tmux): PageUp/PageDown pedem pro claude rolar a
            // própria view — igualzinho ao scroll no PC.
            .overlay(alignment: .trailing) {
                VStack(spacing: 12) {
                    scrollChevron("chevron.up.2", "PageUp")
                    scrollChevron("chevron.down.2", "PageDown")
                }
                .padding(.trailing, 10)
            }
        }
    }

    private func scrollChevron(_ symbol: String, _ key: String) -> some View {
        Button {
            Task { await model.sendKey(key) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.fg)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(theme.fg.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if model.screen.isEmpty {
            Text("conectando ao terminal…")
                .font(.system(size: fontPt, design: .monospaced))
                .foregroundStyle(theme.fg.opacity(0.5))
        } else {
            Text(Ansi.attributed(model.screen, size: fontPt, defaultColor: theme.fg))
        }
    }

    // MARK: Barra de teclas especiais

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                fontButton("textformat.size.smaller", delta: -1)
                fontButton("textformat.size.larger", delta: 1)
                Divider().frame(height: 22)
                keyButton("esc", "Escape")
                keyButton("⌃C", "C-c", tint: .red)
                keyButton("⇥", "Tab")
                // Enter entre Tab e as setas: mais fácil de alcançar (é a tecla mais usada).
                keyButton("⏎", "Enter")
                keyButton("↑", "Up")
                keyButton("↓", "Down")
                keyButton("←", "Left")
                keyButton("→", "Right")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func fontButton(_ symbol: String, delta: Double) -> some View {
        Button {
            fontPtStored = min(fontMax, max(fontMin, fontPtStored + delta))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 42, minHeight: 34)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(delta < 0 ? fontPtStored <= fontMin : fontPtStored >= fontMax)
    }

    private func keyButton(_ label: String, _ key: String, tint: Color = .secondary) -> some View {
        Button {
            Task { await model.sendKey(key) }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint == .red ? .red : .primary)
                .frame(minWidth: 42, minHeight: 34)
                .background(tint == .red ? Color.red.opacity(0.14) : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Input de texto

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("digitar no terminal…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                let text = input
                input = ""
                Task { await model.send(text) }
            } label: {
                if model.sending {
                    ProgressView().tint(.white).frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Detalhes da sessão ao vivo (antes de abrir o terminal)

/// Mostra detalhes de uma sessão viva do Mac — título, máquina e a ÁRVORE de
/// pastas de onde ela roda — e um botão para abrir o terminal ao vivo.
struct LiveDetailView: View {
    let entry: LiveEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Sessão") {
                detailRow("Nome", entry.session.title)
                detailRow("Máquina", entry.machine, symbol: machineSymbol(entry.machine))
                detailRow("Pane", entry.id, mono: true)
            }

            Section("Pasta") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.session.pathComponents.enumerated()), id: \.offset) { idx, comp in
                        HStack(spacing: 6) {
                            Image(systemName: idx == entry.session.pathComponents.count - 1 ? "folder.fill" : "folder")
                                .foregroundStyle(.secondary).font(.caption)
                            Text(comp).font(.system(.callout, design: .monospaced)).lineLimit(1)
                        }
                        .padding(.leading, CGFloat(idx) * 14)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Sessão ao vivo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Fechar") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Label("ao vivo", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
            }
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                TerminalMirrorView(machine: entry.machine, target: entry.id, title: entry.session.title)
            } label: {
                Label("Abrir terminal ao vivo", systemImage: "terminal")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    /// Uma linha de detalhe compacta (rótulo à esquerda, valor à direita em uma
    /// linha só). Substitui LabeledContent, que em List às vezes estica a linha
    /// num container gigante.
    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, symbol: String? = nil, mono: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(value)
                    .font(mono ? .caption.monospaced() : .body)
                    .foregroundStyle(mono ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
