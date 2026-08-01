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

    @AppStorage("cutuque.terminalTheme") private var themeRaw = TerminalTheme.dark.rawValue
    @AppStorage("cutuque.terminalFont") private var fontPhone: Double = 10
    @AppStorage("cutuque.terminalFont.pad") private var fontPad: Double = 13

    private var theme: TerminalTheme { TerminalTheme(rawValue: themeRaw) ?? .dark }
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
            ToolbarItem(placement: .principal) { seletor }
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
            theme.bg.ignoresSafeArea(edges: .bottom)

            PTYTerminalView(session: session, isActive: terminalAtivo,
                            theme: theme, fontSize: fontPt)
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
