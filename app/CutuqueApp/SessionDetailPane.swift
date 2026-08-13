import SwiftUI

/// Painel de detalhe de uma sessão no iPad: chat e terminal empilhados, com um
/// seletor no topo.
///
/// Os dois ficam na hierarquia o tempo todo, alternando por opacidade — trocar
/// de aba não remonta nada, então a rolagem do chat e o espelho do tmux
/// sobrevivem à troca. O terminal para de fazer poll por `isActive`, não por
/// desmontagem.
struct SessionDetailPane: View {
    let selection: DetailSelection
    /// Estado da ABA (G6): `.ativo` quando ela está em foco, `.suspenso`
    /// quando está viva mas atrás de outra, `.liberado` quando dormiu (teto
    /// de 6) ou foi fechada. Vem de `OpenTabs.estado(de:)` — este painel não
    /// decide isso por conta própria.
    let paneState: TerminalPaneState
    /// [12/08/2026] Identidade da aba que este painel representa
    /// (`ChaveDeAba.para(selection)`, calculada por quem monta — ver
    /// `RootSplitView.painel(_:)`). É a chave sob a qual este painel lê/
    /// escreve o modo em `NavigationState` — nunca o `nav.paneMode` cru
    /// direto, porque N `SessionDetailPane` ficam montados ao mesmo tempo
    /// (decisão #19) e cada um precisa do PRÓPRIO modo, não do de um vizinho.
    let chave: ChaveDeAba
    @EnvironmentObject private var nav: NavigationState
    @ObservedObject private var namer = SessionNamesStore.shared
    /// Título ao vivo do chat, subido pelo `SessionDetailView` via
    /// `LiveChatTitleKey` (acompanha `session_updated`/`snapshot`,
    /// desacoplado do snapshot congelado de `nav.selection` — ver o
    /// comentário na chave e em `SessionDetailPaneLogic.resolvedChatTitle`).
    /// `nil` até a primeira preference chegar (mostra o fallback estático
    /// enquanto isso).
    @State private var liveChatTitle: String?

    private var session: Session? {
        if case .session(let s) = selection { return s }
        return nil
    }

    /// A entrada ao vivo do tmux, quando é disso que se trata. É ela que dá o
    /// painel de informações — o mesmo miolo que o iPhone mostra antes de
    /// abrir o terminal (`LiveInfoList`).
    private var liveEntry: LiveEntry? {
        if case .live(let e) = selection { return e }
        return nil
    }

    /// Alvo tmux desta seleção: uma entrada ao vivo sempre tem; uma sessão do
    /// registry só se ela roda dentro do tmux. Decisão pura (testável sem
    /// hosting de View) em `SessionDetailPaneLogic.terminalTarget`.
    private var terminal: (machine: String, target: String, title: String)? {
        SessionDetailPaneLogic.terminalTarget(for: selection) { namer.displayTitle(for: $0) }
    }

    /// [12/08/2026] O modo que ESTE painel renderiza agora — nunca o
    /// `nav.paneMode(de: chave)` guardado cru. Passa por
    /// `SessionDetailPaneLogic.modoValido`, que traduz um modo IMPOSSÍVEL
    /// pra esta seleção (herdado de quando `chave` guardava outra coisa, ou
    /// de uma aba de vizinho que empurrou `.chat`/`.terminal` globalmente
    /// antes desta correção) pro primeiro segmento do seletor. Sem essa
    /// tradução, `showsChat`/`showsTerminal`/`showsInfo` podiam sair todos
    /// `false` juntos — painel em foco em BRANCO até a usuária tocar no
    /// seletor (achado crítico da revisão adversarial pós-G6).
    private var modo: PaneMode {
        SessionDetailPaneLogic.modoValido(
            nav.paneMode(de: chave),
            hasChat: session != nil, hasTerminal: terminal != nil, hasInfo: liveEntry != nil
        )
    }

    private var showsChat: Bool { modo == .chat }

    /// O terminal só fica ATIVO quando é ele que está na frente. Antes isto
    /// era `!showsChat` — com três modos, "não é chat" passou a incluir
    /// `.info`, e o espelho ficaria fazendo poll por trás da tela de
    /// informações. Ele continua MONTADO nos três casos (é o que preserva o
    /// pane do tmux, decisão #19); o que muda é só o poll.
    private var showsTerminal: Bool { modo == .terminal }

    private var showsInfo: Bool { modo == .info }

    /// Título do chat pra entrar em `paneTitle`: prefere o ao vivo
    /// (`liveChatTitle`, subido via `LiveChatTitleKey`) e só cai pro estático
    /// (apelido sobre o snapshot congelado de `session`) antes da primeira
    /// preference chegar. Decisão pura em
    /// `SessionDetailPaneLogic.resolvedChatTitle`.
    private var chatTitle: String? {
        SessionDetailPaneLogic.resolvedChatTitle(
            live: liveChatTitle,
            fallback: session.map { namer.displayTitle(for: $0) }
        )
    }

    /// Único título de navegação do pane — `SessionDetailView`/
    /// `TerminalMirrorView` embutidas aqui recebem `ownsNavigationTitle:
    /// false` e não contribuem mais nada ao `.navigationTitle` (nem uma
    /// string vazia). Decisão pura em `SessionDetailPaneLogic.paneTitle`.
    private var paneTitle: String {
        SessionDetailPaneLogic.paneTitle(
            showsChat: showsChat,
            chatTitle: chatTitle,
            terminalTitle: terminal?.title
        )
    }

    var body: some View {
        ZStack {
            if let session {
                SessionDetailView(session: session, isActive: showsChat, ownsNavigationTitle: false)
                    .opacity(showsChat ? 1 : 0)
                    .allowsHitTesting(showsChat)
                    .accessibilityHidden(!showsChat)
            }
            if let terminal {
                // Regra composta do espelho (G6): só faz poll se a ABA está em
                // foco (`paneState == .ativo`) E o seletor está no terminal
                // (`showsTerminal`). Uma aba viva com o seletor no chat
                // mantém a largura (`.suspenso`) mas não faz poll; `✕`
                // (paneMode = .info) e abas dormindo/fechadas continuam indo
                // pra `.liberado`, que devolve a largura ao tmux — NÃO é kill,
                // a sessão segue trabalhando, é a instrução literal da
                // Vanessa acima.
                let estadoDoEspelho: TerminalPaneState = showsTerminal
                    ? paneState
                    : (paneState == .liberado ? .liberado : .suspenso)
                TerminalMirrorView(machine: terminal.machine, target: terminal.target,
                                   title: terminal.title,
                                   paneState: estadoDoEspelho,
                                   ownsNavigationTitle: false)
                    .opacity(showsTerminal ? 1 : 0)
                    .allowsHitTesting(showsTerminal)
                    .accessibilityHidden(!showsTerminal)
            }
            // As informações da sessão ao vivo. Ficam empilhadas como as
            // outras, e é isso que faz o ✕ do terminal ser barato: sair do
            // terminal é trocar de opacidade, não desmontar nada — o pane do
            // tmux do outro lado segue vivo e trabalhando, que é o que a
            // usuária pediu ("nao é pra kill, é apenas pra fechar o terminal
            // mas ele deve continuar trabalhando na sessao tmux"). O ⊗
            // vermelho que ENCERRA o pane continua sendo outro botão, dentro
            // da própria `TerminalMirrorView`.
            if let liveEntry {
                LiveInfoList(entry: liveEntry)
                    .opacity(showsInfo ? 1 : 0)
                    .allowsHitTesting(showsInfo)
                    .accessibilityHidden(!showsInfo)
            }
        }
        .navigationTitle(paneTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Único leitor de `LiveChatTitleKey` — só o `SessionDetailView`
        // escreve nela, sem concorrência a resolver.
        .onPreferenceChange(LiveChatTitleKey.self) { liveChatTitle = $0 }
        // [13/08/2026] Este painel NÃO desenha mais seletor nem ⤡: quem
        // desenha os dois agora é a `ChromeDaAba`, uma faixa fora dos
        // painéis, UMA vez, para a aba em foco. Antes o seletor morava aqui
        // como `ToolbarItem(placement: .principal)` e o ⤡ como
        // `.topBarTrailing` — com N painéis montados ao mesmo tempo (decisão
        // #19, é o que preserva o `ssh`/o espelho do tmux ao trocar de aba),
        // N desses `ToolbarItem` disputavam a MESMA navigation bar e o
        // SwiftUI escondia quase todos: a causa raiz de "não ta aparecendo o
        // terminal / info embaixo da aba em terminais live e tal". O painel
        // agora só DECLARA o que tem (`.task` abaixo) e traduz de volta a
        // escolha da chrome (`.onChange` abaixo) — nunca mais desenha nada.
        //
        // O ✕ de fechar o terminal CONTINUA aqui (é ação do painel, não da
        // chrome), mas ganhou a guarda que faltava: `paneState == .ativo` é
        // "esta ABA está em foco" (ver o comentário de `paneState`, no topo
        // do arquivo). Sem ela, duas abas ao vivo em modo terminal
        // publicariam dois ✕ no mesmo `.topBarTrailing` — a mesma disputa de
        // N-painéis-uma-toolbar, só que neste placement em vez do
        // `.principal`. Achado do diagnóstico desta leva (13/08/2026), nunca
        // chegou a ser reportado pela Vanessa porque o ✕ "errado" ainda
        // fechava ALGUM terminal — só não necessariamente o da aba tocada.
        .toolbar {
            if liveEntry != nil, showsTerminal, paneState == .ativo {
                ToolbarItem(placement: .topBarTrailing) { closeTerminalButton }
            }
        }
        // Declara o que esta aba tem, e mantém a declaração em dia quando a
        // sessão ganha terminal ou entrada ao vivo. `.task(id:)` só reroda
        // quando `assinaturaDosSegmentos` MUDA — sem o `id`, rodaria a cada
        // recomposição e cada uma delas chamaria `nav.definirSegmentos`
        // (idempotente, mas ainda um `@Published` a mais sendo lido/escrito
        // à toa a cada render).
        .task(id: assinaturaDosSegmentos) {
            nav.definirSegmentos(
                SessionDetailPaneLogic.segmentosDeChrome(
                    hasChat: session != nil, hasTerminal: terminal != nil, hasInfo: liveEntry != nil),
                de: chave)
            nav.escolher(modo.rawValue, de: chave)   // reflete o modo já guardado
        }
        // A chrome escreveu (toque no seletor): aplica no guardado desta
        // aba. Uma direção só — o painel nunca escreve em `nav.escolha`
        // diretamente, só lê. `PaneMode(rawValue:)` falha silenciosamente
        // (`guard let`) se algum dia os ids divergirem do `rawValue`; ver o
        // comentário de `segmentosDeChrome` sobre por que isso não deveria
        // acontecer.
        .onChange(of: nav.escolha(de: chave)) { _, novo in
            guard let novo, let modo = PaneMode(rawValue: novo) else { return }
            nav.definirPaneMode(modo, de: chave)
        }
        .onAppear {
            // Onde este painel abre: seleção sem chat não pode mostrar chat, e
            // entrada ao vivo abre no terminal. Decisão pura (testável sem
            // hosting de View) em `SessionDetailPaneLogic.entryPaneMode`.
            //
            // [12/08/2026] Lê e escreve na CHAVE desta aba, não em
            // `nav.paneMode` cru — por decisão #19 a aba fica montada pra
            // sempre depois de criada, então este `.onAppear` dispara UMA vez
            // só, na criação. Escrever no global aqui é exatamente o achado
            // crítico da revisão pós-G6: a segunda aba aberta forçaria o modo
            // de entrada dela sobre TODAS as outras.
            if let entry = SessionDetailPaneLogic.entryPaneMode(
                hasChat: session != nil, hasTerminal: terminal != nil,
                hasInfo: liveEntry != nil, current: nav.paneMode(de: chave)
            ) {
                nav.definirPaneMode(entry, de: chave)
            }
        }
    }

    /// [13/08/2026] Assinatura de "o que esta aba tem", usada como `id` do
    /// `.task` que publica os segmentos na chrome — string, não uma tupla ou
    /// struct própria, porque `.task(id:)` só precisa comparar por
    /// `Equatable` e três `Bool` concatenados já bastam pra isso. Muda
    /// exatamente quando `session`/`terminal`/`liveEntry` mudam de nil-ou-não
    /// (sessão ganha pane tmux, entrada ao vivo aparece), nunca por causa de
    /// campos que mudam VALOR sem mudar de nil-ou-não — não precisa mais que
    /// isso para decidir se os segmentos declarados ficaram desatualizados.
    private var assinaturaDosSegmentos: String {
        "\(session != nil)-\(terminal != nil)-\(liveEntry != nil)"
    }

    /// O ✕ que a usuária pediu: no iPad o terminal ao vivo não tinha saída
    /// nenhuma ("nao tem como fechar o popup como no iphone"). Ele NÃO encerra
    /// coisa alguma — só volta pras informações da sessão. O espelho fica
    /// montado e apenas para de fazer poll (`isActive`), então o tmux do outro
    /// lado continua trabalhando.
    ///
    /// De propósito sem `role: .destructive` e sem confirmação, ao contrário
    /// do ⊗ vermelho da `TerminalMirrorView`, que mata o pane. São dois botões
    /// diferentes com dois efeitos diferentes, e é por isso que este é um ✕
    /// simples e cinza.
    private var closeTerminalButton: some View {
        Button {
            nav.definirPaneMode(.info, de: chave)
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Fechar o terminal")
    }
}

extension Animation {
    /// Curva de toda chamada a `nav.toggleColumns()`. `⌘⌃F` tem duas
    /// superfícies legítimas — o botão de tela cheia da `ChromeDaAba` e o item
    /// de menu equivalente em `CutuqueCommands` — e as duas precisam da MESMA
    /// curva: como o mesmo atalho de teclado só pode ter um handler resolvido
    /// pelo sistema, se cada superfície animasse diferente o colapso ora
    /// animava, ora saltava, dependendo de qual delas o iPadOS escolhesse.
    /// Fonte única aqui em vez de duplicar o literal `.easeInOut(duration:
    /// 0.2)` nos arquivos que consomem.
    ///
    /// [13/08/2026] Este tipo já foi o terceiro: até esta leva, `SessionDetailPane`
    /// TAMBÉM tinha um botão de tela cheia próprio (`expandButton`,
    /// `ToolbarItem(.topBarTrailing)`) com o MESMO `keyboardShortcut("f",
    /// modifiers: [.command, .control])`. Com N painéis montados (decisão
    /// #19), isso era um SEGUNDO registro do mesmo atalho global — atalho
    /// duplicado em N views é sorteio de qual delas o SwiftUI escolhe para
    /// responder. O botão saiu daqui: a `ChromeDaAba` (fora dos painéis,
    /// desenhada uma única vez) é agora a ÚNICA dona do ⌘⌃F por botão; a
    /// extensão fica neste arquivo por não ter um lar mais natural depois da
    /// remoção, e porque `CutuqueCommands` e `ChromeDaAba` já dependiam dela
    /// daqui.
    static var columnToggle: Animation { .easeInOut(duration: 0.2) }
}
