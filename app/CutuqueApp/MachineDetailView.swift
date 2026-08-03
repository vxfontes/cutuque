import SwiftUI

/// Um host aberto: terminal livre e navegação de arquivos, no mesmo lugar.
///
/// Os dois painéis ficam MONTADOS ao mesmo tempo e alterna-se a opacidade
/// (molde do `SessionDetailPane`). Não é economia de código — é a única forma
/// de trocar de painel sem consequência: desmontar o terminal fecharia o
/// WebSocket, e o hub mata o `ssh` junto (sessão efêmera, sem tmux para
/// sobreviver). O inativo recebe `isActive: false` e para o trabalho de fundo.
struct MachineDetailView: View {
    let machine: Machine

    @StateObject private var session: PTYSession
    /// Painel aberto, lembrado POR HOST: a máquina onde se edita arquivo e a
    /// máquina onde se roda comando não são a mesma.
    @AppStorage private var paneRaw: String
    /// Falso enquanto uma subpasta está empilhada por cima — o terminal para de
    /// consumir o socket enquanto ninguém o vê.
    @State private var naTela = true
    /// Erro de conexão já mostrado; guardado para o botão de reconectar saber
    /// que há o que refazer.
    @State private var reconectando = false

    @AppStorage("cutuque.terminalFont") private var fontPhone: Double = 10
    @AppStorage("cutuque.terminalFont.pad") private var fontPad: Double = 13

    /// Tema e ícone vivem em `@State`, não na `machine` recebida, e isso é o que
    /// mantém a sessão viva ao trocar de cor: no iPad o painel é identificado pela
    /// máquina selecionada, então reescrever a seleção com uma `Machine` de tema
    /// novo destruiria esta view — fechando o WebSocket e matando o `ssh` do outro
    /// lado. O hub já foi atualizado pela sheet; a lista relê quando reabre.
    @State private var tema: String
    @State private var icone: String
    private struct SheetInfo: Identifiable { let id = "info" }
    @State private var sheetInfo: SheetInfo?

    /// Tema É por máquina agora (pedido da usuária) — não mais preferência
    /// global. `""`/ausente cai no Padrão dentro do próprio `TerminalPalette`.
    private var paleta: TerminalPalette { TerminalPalette.byID(tema) }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var fontPt: CGFloat { CGFloat(isPad ? fontPad : fontPhone) }

    private var pane: MachinePane { MachinePane(rawValue: paneRaw) ?? .terminal }
    private var showsTerminal: Bool { pane == .terminal }

    /// O terminal só trabalha quando é o painel aberto E está na tela.
    private var terminalAtivo: Bool { showsTerminal && naTela }

    init(machine: Machine) {
        self.machine = machine
        _session = StateObject(wrappedValue: PTYSession(machine: machine.name))
        _paneRaw = AppStorage(wrappedValue: MachinePane.terminal.rawValue,
                              MachinePane.storageKey(machine: machine.name))
        _tema = State(initialValue: machine.theme ?? "")
        _icone = State(initialValue: machine.icon ?? "")
    }

    var body: some View {
        ZStack {
            terminalPane
                .opacity(showsTerminal ? 1 : 0)
                .allowsHitTesting(showsTerminal)
                .accessibilityHidden(!showsTerminal)

            FileBrowserView(machine: machine.name, path: "",
                            ownsNavigationTitle: false, isActive: !showsTerminal)
                .opacity(showsTerminal ? 0 : 1)
                .allowsHitTesting(!showsTerminal)
                .accessibilityHidden(showsTerminal)
        }
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { identidadeENavigationBarLeading }
            ToolbarItem(placement: .principal) { seletor }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { sheetInfo = SheetInfo() } label: {
                    Image(systemName: "paintpalette")
                }
                .accessibilityLabel("Informações e aparência")
            }
        }
        .sheet(item: $sheetInfo) { _ in
            MachineInfoSheet(machine: machine, tema: $tema, icone: $icone) {
                // A lista relê do hub; a `machine` desta view segue a mesma de
                // propósito (trocá-la destruiria o painel — ver o comentário do
                // `@State tema`).
                NotificationCenter.default.post(name: .maquinasMudaram, object: nil)
            }
        }
        // Empilhar uma subpasta chama o `onDisappear` desta view: o terminal
        // para de ler, mas o socket segue aberto e o shell do outro lado vivo —
        // voltar reencontra tudo onde estava.
        .onAppear { naTela = true }
        .onDisappear { naTela = false }
        .onChange(of: terminalAtivo) { _, ativo in
            if ativo {
                // A ordem importa: `abre()` para quem chegou nos arquivos e só
                // depois foi ao terminal (nunca houve conexão); `resume()` para
                // quem já tinha uma, suspensa.
                session.abre()
                session.resume()
            } else {
                session.suspend()
            }
        }
    }

    /// Ícone pelo SO detectado + usuário da identidade, quando há — pista de
    /// "em quem" e "onde" sem abrir outra tela. Ao lado do botão de voltar
    /// automático: fica compacto de propósito (não é lugar pra texto longo).
    @ViewBuilder
    private var identidadeENavigationBarLeading: some View {
        // `icone` (o @State) e não `machine.icon`: a escolha feita na sheet aparece
        // aqui na hora, e a `machine` recebida segue intocada de propósito.
        let simbolo = MachineIcon.symbol(escolhido: icone, os: machine.os)
        if let identidade = machine.identity, !identidade.isEmpty {
            Label(identidade, systemImage: simbolo)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: simbolo)
                .foregroundStyle(.secondary)
        }
    }

    private var seletor: some View {
        Picker("Painel", selection: Binding(get: { pane }, set: { paneRaw = $0.rawValue })) {
            ForEach(MachinePane.allCases, id: \.self) { p in
                Label(p.label, systemImage: p.symbol).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleOnly)
        .frame(maxWidth: 220)
    }

    @ViewBuilder
    private var terminalPane: some View {
        ZStack {
            paleta.backgroundColor.ignoresSafeArea(edges: .bottom)

            PTYTerminalView(session: session, isActive: terminalAtivo,
                            themeID: tema, fontSize: fontPt)
                // O teclado do sistema sobe por cima; sem isto ele cobriria as
                // últimas linhas em vez de empurrá-las.
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if let recado = session.estado.recado {
                encerrado(recado)
            }
        }
    }

    /// A tela fica visível por baixo: o que estava escrito quando o shell caiu
    /// costuma ser justamente o motivo (uma mensagem de erro do ssh, um `exit`
    /// não intencional).
    private func encerrado(_ recado: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(recado)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button {
                reconecta()
            } label: {
                Label("Abrir de novo", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(reconectando)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
        .transition(.opacity)
    }

    /// Reconectar abre um shell NOVO — não recupera o antigo. É por isso que é
    /// um botão, e não automático: o `liveUpdates()` pode reconectar sozinho
    /// porque lá o estado está todo no hub; um shell é estado local (diretório,
    /// variáveis, o que estava aberto) e um reconectar silencioso entregaria
    /// um shell diferente com cara do mesmo.
    private func reconecta() {
        reconectando = true
        session.disconnect()
        // O tamanho medido segue guardado na sessão: o shell novo já nasce do
        // tamanho da tela.
        session.abre()
        reconectando = false
    }
}
