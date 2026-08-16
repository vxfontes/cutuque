import SwiftUI
import UIKit

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
            var pacer = PollPacer()
            let relogio = ContinuousClock()
            // [16/08/2026] Instante do último `record` — substitui a antiga
            // `sonoAnterior` (o sono PLANEJADO da rodada anterior). O
            // problema da antiga: se o app suspende, o `Task.sleep` estoura
            // MUITO além do planejado, mas `sonoAnterior` continuava com o
            // número pequeno de antes — o `elapsed` passado ao pacer mentia
            // pra menos e a rampa demorava a subir. Guardando o INSTANTE em
            // vez do sono, `DecorridoReal.desde` mede a diferença de parede
            // entre duas voltas — suspensão incluída de graça. `nil` na
            // primeira volta: sem registro anterior, ver `DecorridoReal`.
            var ultimoRegistro: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self else { return }
                let t0 = relogio.now
                let changed = await self.refresh()
                let agora = relogio.now
                // Custo REAL da requisição — RTT de Tailscale+SSH+capture-pane
                // incluído. É o que faltava para descontar do sleep (defeito 1).
                let custo = agora - t0
                // Tempo REAL decorrido desde o `record` anterior (defeito 3,
                // agora à prova de suspensão — ver `DecorridoReal`). Lido e
                // gravado ANTES de `pacer.interval` ser consultado de novo
                // (defeito 2): a decisão de quanto dormir já enxerga o
                // resultado da rodada que acabou de rodar, então uma tecla
                // digitada agora derruba `quietFor` a zero e o sono seguinte
                // já sai no piso — não espera uma volta inteira do laço para
                // reagir.
                let decorrido = DecorridoReal.desde(ultimoRegistro: ultimoRegistro, agora: agora, custo: custo)
                pacer.record(changed: changed, elapsed: decorrido.seconds)
                ultimoRegistro = agora
                let alvo = pacer.interval
                let sono = SonoRestante.duracao(alvo: alvo, custo: custo, piso: PollPacer.piso)
                try? await Task.sleep(for: sono)
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
    /// re-parsear ANSI à toa a cada poll. Devolve se houve diff, para o pacer.
    @discardableResult
    private func refresh() async -> Bool {
        let s = await api.tmuxScreen(machine: machine, target: target)
        guard !s.isEmpty, s != screen else { return false }
        screen = s
        return true
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
    /// O estado do painel. Três valores porque o `✕` do iPad e a troca de aba são
    /// coisas diferentes: um devolve a largura ao tmux, o outro a mantém. Era um
    /// `Bool isActive` — o booleano é o que deixava o pane preso na grade do iPad.
    var paneState: TerminalPaneState = .ativo
    /// Falso quando embutida no `SessionDetailPane` do iPad, que passa a ser
    /// a ÚNICA fonte de `.navigationTitle` (ver `OwnedNavigationTitle.swift`).
    /// Default `true` preserva o iPhone, que monta esta view sozinha e nunca
    /// passa nada aqui.
    var ownsNavigationTitle: Bool = true

    @StateObject private var model: TerminalMirrorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    // [13/08/2026] `Color.accentColor` não lê o `.tint()` da raiz (ver
    // `AppTheme.swift`) — era por isso que o botão de enviar ficava sempre
    // azul, mesmo trocando a cor em Ajustes.
    @Environment(\.corDeDestaque) private var destaque
    @State private var input = ""
    @State private var confirmingKill = false
    /// Marca de uso ÚNICO: o `.onKeyPress` vê o ⇧⏎ antes de o TextField inserir a
    /// quebra, e é só assim que o `.onChange` seguinte sabe distinguir "quebra
    /// pedida de propósito" de "Enter para enviar" — ver ComposerEnter.
    @State private var quebraIntencional = false
    @FocusState private var inputFocused: Bool
    @AppStorage("cutuque.terminalTheme") private var themeRaw = TerminalTheme.dark.rawValue
    private var theme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dark }

    // Tamanho da fonte, ajustável (A−/A+). Menor = mais colunas = a TUI do claude
    // renderiza mais larga (parecida com o PC); maior = mais legível.
    // Duas chaves: o tamanho bom no iPhone (10 pt, 393 pt de largura) é miúdo
    // demais num painel de iPad, e vice-versa. Cada plataforma lembra o seu.
    @AppStorage("cutuque.terminalFont") private var fontPhone: Double = 10
    @AppStorage("cutuque.terminalFont.pad") private var fontPad: Double = 13
    /// Gaveta das letras de comando (`j k x r p s`) na barra de teclas. Fechada por
    /// padrão: só faz sentido com uma TUI de workflow rodando no pane.
    @AppStorage("cutuque.terminalLetrasDeComando") private var letrasAbertas = false
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var fontPtStored: Double {
        get { isPad ? fontPad : fontPhone }
        nonmutating set { if isPad { fontPad = newValue } else { fontPhone = newValue } }
    }
    private var fontPt: CGFloat { CGFloat(fontPtStored) }
    private let fontMin = TerminalGeometry.fontMin
    private let fontMax = TerminalGeometry.fontMax

    /// Segura a rajada de resize do arraste do divisor do Split View.
    @State private var resizeDebouncer = ResizeDebouncer()

    /// Tamanho do VIEWPORT do terminal — a `ScrollView`, não o painel inteiro.
    /// Medido pelo `.background` de `terminal`, o que dispensa descontar as
    /// barras de teclas e de input por estimativa (era a constante
    /// `verticalChrome = 120`): elas simplesmente ficam fora do retângulo
    /// medido.
    @State private var viewport: CGSize = .zero

    /// Largura de um caractere e altura de uma linha, medidas pela `ruler`.
    /// `nil` até a primeira medição — enquanto isso não se pede resize nenhum
    /// ao tmux, porque um palpite aqui é exatamente o que esta mudança veio
    /// tirar (ver `TerminalGeometry`).
    @State private var metrics: TerminalGeometry.TextMetrics?

    /// Colunas e linhas que cabem AGORA, ou `nil` enquanto falta medição.
    private var grid: (cols: Int, rows: Int)? {
        guard let metrics, metrics.isUsable, viewport.width > 0, viewport.height > 0
        else { return nil }
        return (TerminalGeometry.columns(width: viewport.width, metrics: metrics),
                TerminalGeometry.rows(height: viewport.height, metrics: metrics))
    }

    /// Identidade do `.task` que dispara o resize. O caso sem medição precisa
    /// de um valor PRÓPRIO (não `"0x0"`, que poderia colidir com uma grade
    /// real de piso) só pra o `.task` reentrar quando a medida chegar.
    private var resizeKey: String {
        TerminalResizeKey.chave(cols: grid?.cols, rows: grid?.rows, estado: paneState)
    }

    /// A tela do espelho como texto colável, NO INSTANTE da leitura.
    ///
    /// É por isso que copiar funciona aqui: `model.screen` é `@Published` e
    /// chega do WebSocket a cada atualização de tela, então a seleção nativa
    /// morre a cada quadro (e o auto-scroll animado do `.onChange` interrompe o
    /// gesto). Uma `String` copiada agora não muda mais, aconteça o que
    /// acontecer atrás dela.
    private var telaColavel: String {
        TextoParaCopiar.aparado(Ansi.plain(model.screen))
    }

    /// Retrato congelado pedido pela usuária.
    ///
    /// Guarda o embrulho, e NÃO uma `String?` mapeada no `body`: `.map` no
    /// binding criaria um `id` novo a cada avaliação do `body` — e como o
    /// `model.screen` republica sem parar, o `.sheet(item:)` acharia que o item
    /// mudou a cada quadro e ficaria reapresentando a folha em laço.
    @State private var folhaDaTela: TextoIdentificavel?

    init(machine: String, target: String, title: String, paneState: TerminalPaneState = .ativo,
         ownsNavigationTitle: Bool = true) {
        self.machine = machine
        self.target = target
        self.title = title
        self.paneState = paneState
        self.ownsNavigationTitle = ownsNavigationTitle
        _model = StateObject(wrappedValue: TerminalMirrorModel(machine: machine, target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            terminal
            keyBar
            inputBar
        }
        // Antes havia um `GeometryReader` embrulhando este `VStack` só pra ler
        // a altura do painel INTEIRO e dela subtrair um chute de 120 pt pras
        // duas barras. Agora quem mede é o `.background` do próprio
        // `terminal` (a `ScrollView`), então não sobra nada pra estimar — e o
        // `GeometryReader`, que participava do layout, sai da árvore.
        .task(id: resizeKey) {
            // Painel liberado não fixa largura nenhuma: agenda o contrário, devolver.
            if paneState == .liberado {
                resizeDebouncer.cancel()
                model.stop()
                model.restoreSize()
                return
            }
            if let grid {
                resizeDebouncer.schedule(cols: grid.cols, rows: grid.rows) { c, r in
                    model.resize(cols: c, rows: r)
                }
            }
            if paneState.fazPolling { model.start() } else { model.stop() }
        }
        .onChange(of: paneState) { anterior, novo in
            // A largura é devolvida na TRANSIÇÃO para liberado, não no estado — ver
            // TerminalPaneState.devolveLargura. Suspender (aba de trás) mantém.
            if TerminalPaneState.devolveLargura(de: anterior, para: novo) {
                resizeDebouncer.cancel()
                model.restoreSize()
            }
            if novo.fazPolling { model.start() } else { model.stop() }
        }
        .onChange(of: scenePhase) { _, fase in
            switch TerminalCenaLogic.acao(fase: fase, estado: paneState) {
            case .devolver:
                resizeDebouncer.cancel()
                model.restoreSize()
            case .reaplicar:
                if let grid { model.resize(cols: grid.cols, rows: grid.rows) }
            case .nada:
                break
            }
        }
        // Título de navegação: só quando esta view é dona dele (iPhone,
        // sozinha). Embutida no `SessionDetailPane` do iPad ela recebe
        // `ownsNavigationTitle: false` e não contribui NADA ao
        // `.navigationTitle` — nem uma string vazia — porque o pane é a
        // única fonte (ver `OwnedNavigationTitle.swift`): duas views
        // simultaneamente montadas competindo pelo mesmo preference key,
        // mesmo que uma delas mande `""`, ainda é uma disputa cujo vencedor
        // depende de composição interna do SwiftUI, não de garantia nossa.
        //
        // Toolbar: gate no CONTEÚDO (não no modificador em si) — não é
        // `if/else` na árvore de views, então não remonta nada (decisão
        // #19). Sem isto, o painel Chat|Terminal do iPad (que mantém as duas
        // views vivas ao mesmo tempo, ver `SessionDetailPane`) tinha o X
        // vermelho de "Encerrar sessão do tmux" tocável na toolbar mesmo com
        // o Chat em foco — `.toolbar` compõe as contribuições de TODAS as
        // views montadas, e `.opacity`/`.allowsHitTesting` não alcançam a
        // barra de navegação.
        .ownedNavigationTitle(title, owns: ownsNavigationTitle)
        .toolbar {
            if paneState == .ativo {
                ToolbarItem(placement: .topBarTrailing) { themeMenu }
                ToolbarItem(placement: .topBarTrailing) { menuDeCopiar }
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
        }
        .onDisappear {
            // Cancela QUALQUER resize debounced ainda pendente antes de
            // parar o poll e restaurar o tamanho. Sem isto: arrastar o
            // divisor e trocar de sessão nos ~300ms seguintes deixava o
            // resize atrasado disparar DEPOIS do restoreSize() — o pane no
            // Mac ficava com o tamanho errado (a troca de sessão usa
            // `.id(selection)`, que destrói este painel e roda este
            // onDisappear na hora). stop()/restoreSize() continuam na
            // mesma ordem de sempre — só o cancel() entra, antes dos dois.
            resizeDebouncer.cancel()
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
        .sheet(item: $folhaDaTela) { pedida in
            FolhaDeTexto(titulo: "Tela do terminal", texto: pedida.texto, monoespacado: true)
        }
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

    /// Copiar a tela do espelho: a coisa inteira em um toque, ou a folha
    /// congelada para selecionar um trecho. Item PRÓPRIO na toolbar (ícone
    /// `doc.on.doc`) — dentro do `themeMenu` (ícone de paleta) a usuária não
    /// acharia.
    private var menuDeCopiar: some View {
        Menu {
            Button {
                AreaDeTransferencia.copiar(telaColavel)
            } label: {
                Label("Copiar tela", systemImage: "doc.on.doc")
            }
            Button {
                folhaDaTela = TextoIdentificavel(telaColavel)
            } label: {
                Label("Selecionar texto…", systemImage: "selection.pin.in.out")
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .disabled(telaColavel.isEmpty)
        .accessibilityLabel("Copiar conteúdo da tela")
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
                    // Os mesmos valores que `TerminalGeometry.columns/rows`
                    // descontam — lidos de lá, não redigitados aqui, pra não
                    // poderem divergir em silêncio.
                    .padding(.horizontal, TerminalGeometry.horizontalTextPadding)
                    .padding(.vertical, TerminalGeometry.verticalTextPadding)
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
            // As duas medições que substituem os antigos números mágicos. Vão
            // em `.background` de propósito: background não altera o tamanho
            // de quem o hospeda, então medir aqui não realimenta o layout.
            .background(viewportReader)
            .background(alignment: .topLeading) { ruler }
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

    /// Mede o viewport do terminal. Mesmo padrão do `RootSplitView`:
    /// `.background(GeometryReader { Color.clear })`, que lê a geometria sem
    /// participar do layout.
    private var viewportReader: some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, size in
                viewport = size
            }
        }
    }

    /// A régua: uma linha de verdade, na fonte de verdade, medida pelo próprio
    /// SwiftUI. É o que substitui as razões 0.62/1.28 — ver o cabeçalho de
    /// `TerminalGeometry` pra por que uma razão fixa não dá conta.
    ///
    /// `.fixedSize()` é obrigatório: dentro de um `.background` a proposta de
    /// tamanho é a do terminal, e sem ele os 100 caracteres quebrariam em
    /// várias linhas — a medida sairia com a largura do painel e a altura de
    /// um parágrafo. Com ele, o `Text` usa o tamanho ideal: uma linha só.
    private var ruler: some View {
        Text(String(repeating: "M", count: TerminalGeometry.sampleLength))
            .font(.system(size: fontPt, design: .monospaced))
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size, initial: true) { _, size in
                        if let measured = TerminalGeometry.TextMetrics(sampleSize: size) {
                            metrics = measured
                        }
                    }
                }
            )
            .hidden()
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
                Divider().frame(height: 22)
                gavetaDeLetras
                if letrasAbertas {
                    ForEach(TerminalKeyboard.letrasDeComando, id: \.self) { letra in
                        keyButton(letra, letra)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    /// O `›`/`‹` que abre e recolhe as letras de comando.
    ///
    /// As seis letras soltas ao lado das setas viravam um paredão — e elas só
    /// servem quando o que está rodando no pane é uma TUI que as escuta. Ficam
    /// guardadas atrás de um toque, e a escolha é lembrada (`@AppStorage`): quem
    /// vive em workflow abre uma vez e pronto.
    private var gavetaDeLetras: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { letrasAbertas.toggle() }
        } label: {
            Text(letrasAbertas ? "‹" : "›")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(minWidth: 42, minHeight: 34)
                .background(Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(letrasAbertas ? "Recolher teclas de comando" : "Mostrar teclas de comando")
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
        .keyboardShortcut(delta < 0 ? "-" : "+", modifiers: .command)
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
                // O TextField é UIKit por baixo (UITextField) e consome ⎋/⇥/setas
                // internamente (mover cursor, navegar campos) antes que o evento
                // suba pro ancestral SwiftUI — por isso o onKeyPress precisa estar
                // pendurado NELE, e não na VStack externa: a view focada tem
                // prioridade na cadeia de onKeyPress e intercepta antes do
                // comportamento default do controle rodar. É também o único
                // elemento focável desta tela, então mover (em vez de duplicar)
                // não perde nenhum caso que já funcionava.
                .onKeyPress(phases: .down) { press in
                    // ⇧⏎ é quebra de linha: deixa o TextField inserir o `\n` e
                    // avisa o onChange para NÃO tratar essa quebra como envio.
                    if ComposerEnter.ehQuebraIntencional(key: press.key, modifiers: press.modifiers) {
                        quebraIntencional = true
                        return .ignored
                    }
                    guard let key = TerminalKeyboard.tmuxKey(for: press.key.character,
                                                             modifiers: press.modifiers)
                    else { return .ignored }
                    Task { await model.sendKey(key) }
                    return .handled
                }
                // ⏎ do teclado DE TELA: ele não passa por onKeyPress nenhum, só
                // injeta um `\n` no binding — então o sinal aqui é a quebra
                // recém-inserida. Este caminho está certo desde 13/08 e não pode
                // ser mexido; o que faltava era o gêmeo do teclado físico, abaixo.
                .onChange(of: input) { anterior, novo in
                    switch ComposerEnter.acao(anterior: anterior, novo: novo,
                                              quebraIntencional: quebraIntencional) {
                    case .nada: break
                    case .limpar: input = ""
                    case .enviar(let texto): enviarInput(texto)
                    }
                    quebraIntencional = false
                }
                // ⏎ do teclado FÍSICO: aqui o Return NÃO escreve `\n` — ele dispara
                // só o onSubmit, e o onChange acima nunca roda. Sem este bloco o
                // Enter do Magic Keyboard não envia nada (bug de 16/08).
                .onSubmit {
                    switch ComposerEnter.acaoSubmit(texto: input,
                                                    quebraIntencional: quebraIntencional) {
                    case .nada: break
                    // No físico ninguém escreve a quebra do ⇧⏎ — quem escreve é aqui.
                    case .inserirQuebra: input += "\n"
                    case .enviar: enviarInput(input)
                    }
                    quebraIntencional = false
                }

            Button {
                enviarInput(input)
            } label: {
                if model.sending {
                    ProgressView().tint(.white).frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(destaque, in: Circle())
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Caminho ÚNICO de envio da linha — botão, ⌘⏎ e ⏎ passam todos por aqui, para
    /// não existir uma via com guarda e outra sem. As guardas são as mesmas que
    /// desabilitam o botão; quando não passam, o texto VOLTA pro campo (⏎ durante
    /// um envio em voo não pode engolir o que ela digitou).
    private func enviarInput(_ texto: String) {
        guard !texto.trimmingCharacters(in: .whitespaces).isEmpty, !model.sending else {
            input = texto
            return
        }
        input = ""
        Task { await model.send(texto) }
    }
}

// MARK: - Detalhes da sessão ao vivo (antes de abrir o terminal)

/// Mostra detalhes de uma sessão viva do Mac — título, máquina e a ÁRVORE de
/// pastas de onde ela roda — e um botão para abrir o terminal ao vivo.
struct LiveDetailView: View {
    let entry: LiveEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LiveInfoList(entry: entry)
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
                    TerminalMirrorView(machine: entry.machine, target: entry.paneTarget, title: entry.session.title)
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
}

/// O CORPO das informações de uma sessão viva — título, máquina, pane e a
/// árvore de pastas — sem barra de navegação, sem botão e sem `dismiss`.
///
/// Nasceu de dentro do `LiveDetailView` acima quando o iPad passou a mostrar as
/// mesmas informações ("no ao vivo do tmux nao ta abrindo as informações como
/// temos no iphone"). Lá elas continuam num sheet com "Fechar" e o botão de
/// abrir o terminal; aqui, num painel de split view com um seletor
/// `Info | Terminal`. Só o miolo é comum, então só o miolo mora aqui — a
/// alternativa (parametrizar o `LiveDetailView` com flags de "mostra toolbar?",
/// "mostra botão?") deixaria uma view fingindo ser duas.
struct LiveInfoList: View {
    let entry: LiveEntry

    var body: some View {
        List {
            Section("Sessão") {
                detailRow("Nome", entry.session.title)
                detailRow("Máquina", entry.machine, symbol: machineSymbol(entry.machine))
                detailRow("Pane", entry.paneTarget, mono: true)
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

/// Embrulho para `.sheet(item:)` com um texto solto. Existe porque `String` não
/// é `Identifiable` e porque o que a folha precisa é o RETRATO, não o binding.
private struct TextoIdentificavel: Identifiable {
    let id = UUID()
    let texto: String
    init(_ texto: String) { self.texto = texto }
}
