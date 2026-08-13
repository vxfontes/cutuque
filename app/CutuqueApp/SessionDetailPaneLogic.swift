import Foundation

/// Decisões puras do painel de detalhe da sessão (`SessionDetailPane`),
/// extraídas para caber em XCTest sem hosting de View — mesmo formato de
/// `BoardMoveLogic`: nada de SwiftUI, nada de rede, só os dois `if/else`
/// reais que a view tinha embutidos.
enum SessionDetailPaneLogic {

    /// Alvo tmux de uma seleção: uma entrada ao vivo sempre tem; uma sessão
    /// do registry só se ela roda dentro do tmux. `displayTitle` resolve o
    /// nome (apelido local, se houver) sem esta função depender do
    /// `SessionNamesStore` — só recebe a `Session` e devolve a string pronta.
    static func terminalTarget(
        for selection: DetailSelection,
        displayTitle: (Session) -> String
    ) -> (machine: String, target: String, title: String)? {
        switch selection {
        case .live(let entry):
            // paneTarget, não `id`: o `id` carrega a máquina (identidade na
            // lista) e o tmux do hub não sabe o que fazer com ela.
            return (entry.machine, entry.paneTarget, entry.session.title)
        case .session(let s):
            guard let target = s.tmuxTarget else { return nil }
            return (s.machine, target, displayTitle(s))
        }
    }

    /// Em que painel o detalhe ABRE, dado o que esta seleção tem. `nil` quando
    /// `current` já serve — não há nada a mudar.
    ///
    /// [12/08/2026] Até a G6, `paneMode` era estado compartilhado em
    /// `NavigationState` — só existia UM `SessionDetailPane` montado por vez,
    /// então corrigir um modo impossível e escolher o padrão de entrada eram
    /// a mesma conta. Com abas, o modo virou POR ABA (quem liga isso na view é
    /// o agente seguinte a este comentário; a correção do modo impossível a
    /// cada render agora é `modoValido`, abaixo). `entryPaneMode` perde a
    /// primeira responsabilidade — ela nunca mais precisa "corrigir" nada,
    /// porque `modoValido` já torna um modo em branco impossível por
    /// construção — e sobra só a segunda: escolher onde a aba NOVA abre
    /// (`onAppear`, uma vez por aba).
    ///
    /// - **Tem info** (entrada ao vivo do tmux): abre SEMPRE em `.terminal`.
    ///   Até 08/2026 isto valia a cada seleção porque o pane era remontado
    ///   por sessão (`.id(selection)` em `RootSplitView`). Com abas (G6) esse
    ///   `.id` saiu — cada aba tem seu próprio `SessionDetailPane`, montado
    ///   uma vez — então agora isto vale na PRIMEIRA vez que uma sessão ao
    ///   vivo abre (nova aba, `onAppear` roda uma vez): escolher uma sessão
    ///   ao vivo NUNCA aberta antes ainda cai no terminal dela; reselecionar
    ///   uma aba que já existia preserva o painel em que a Vanessa deixou.
    ///
    ///   Isto já foi `.info` — a pedido da própria usuária ("antes de abrir
    ///   assim mostra as infos e tudo mais"), pela paridade com o iPhone,
    ///   onde tocar numa linha ao vivo abre `LiveDetailView` e o terminal vem
    ///   de um botão. Ela testou no iPad e mudou de ideia (2026-07-27: "a
    ///   tela de terminal deve ser a primeira a abrir e info deve ser a tela
    ///   da direita no seletor"). No iPad o terminal cabe inteiro ao lado da
    ///   lista, então a escada de toques que fazia sentido no telefone só
    ///   atrasa aqui. A informação não sumiu: virou a aba da direita, e o ✕
    ///   do terminal continua caindo nela.
    /// - **Sem chat e sem info**: só sobra terminal.
    /// - **Com chat**: mantém o que o usuário já escolhia entre chat e
    ///   terminal; `.info` (herdado de uma seleção ao vivo anterior) não
    ///   existe aqui e vira `.chat`, assim como `.terminal` numa sessão fora
    ///   do tmux.
    static func entryPaneMode(hasChat: Bool, hasTerminal: Bool, hasInfo: Bool,
                              current: PaneMode) -> PaneMode? {
        let required: PaneMode
        if hasInfo {
            required = .terminal
        } else if !hasChat {
            required = .terminal
        } else if !hasTerminal || current == .info {
            required = .chat
        } else {
            return nil
        }
        return required == current ? nil : required
    }

    /// Os segmentos do seletor do topo, NA ORDEM em que aparecem. Vazio
    /// quando não há o que alternar (sessão do registry fora do tmux) — e aí
    /// nenhum `ToolbarItem` entra em `.principal`, porque um item vazio ali
    /// ocuparia o lugar do título.
    ///
    /// A ordem não é decorativa: a primeira aba é a que abre. Numa entrada ao
    /// vivo é `Terminal | Info` (ver `entryPaneMode`), numa sessão do registry
    /// que roda no tmux continua `Chat | Terminal`.
    ///
    /// Esta função e `entryPaneMode` leem os mesmos três "tem/não tem" e
    /// precisam concordar: se divergirem, o segmentado abre sem nenhum
    /// segmento marcado. Por isso as duas moram aqui, lado a lado, e os
    /// testes cobrem o par.
    static func selectorSegments(hasChat: Bool, hasTerminal: Bool,
                                 hasInfo: Bool) -> [(label: String, mode: PaneMode)] {
        guard hasTerminal else { return [] }
        if hasInfo { return [("Terminal", .terminal), ("Info", .info)] }
        if hasChat { return [("Chat", .chat), ("Terminal", .terminal)] }
        return []
    }

    /// [13/08/2026] Os segmentos do seletor, no formato que a `ChromeDaAba`
    /// consome (`SegmentoDeChrome`, com `id` cru de `String`) — a versão
    /// testável de `SessionDetailPane.selectorSegments`, que morria dentro da
    /// view e virava `ToolbarItem(placement: .principal)`. Com N painéis
    /// montados ao mesmo tempo (decisão #19), N desses `ToolbarItem`
    /// disputavam a MESMA navigation bar e o SwiftUI escondia quase todos —
    /// a causa raiz de "não ta aparecendo o terminal / info embaixo da aba em
    /// terminais live e tal". A saída (Onda 0, `NavigationState`) é o painel
    /// DECLARAR os segmentos aqui computados, e a `ChromeDaAba` — uma só,
    /// fora dos painéis — desenhar os da aba em foco.
    ///
    /// Não delega para `selectorSegments`: as duas respondem perguntas
    /// diferentes. `selectorSegments` é uma escolha MUTUAMENTE EXCLUSIVA
    /// entre pares (`hasInfo` vence `hasChat` de propósito, porque uma
    /// entrada ao vivo nunca tem chat — ver o comentário lá) pensada para
    /// alimentar `modoValido`, que precisa de UM segmento "primeiro" para
    /// cair quando o modo guardado é impossível. Esta função é mais simples e
    /// mais geral: cada "tem" independente vira um segmento, na ordem fixa
    /// Chat → Terminal → Info, e um único segmento disponível não é escolha
    /// (a chrome mostra só o ⤡). Para toda combinação que de fato ACONTECE no
    /// app (nunca chat+info juntos — ver `terminalTarget`/`PaneMode`), as duas
    /// funções concordam byte a byte; divergem só na combinação impossível
    /// (chat E info juntos), que nenhum estado real produz — por isso não é
    /// duplicação de fonte de verdade, é uma segunda pergunta sobre os mesmos
    /// três booleanos. `modoValido` continua lendo `selectorSegments`, não
    /// esta função — são contratos diferentes e não podem se confundir.
    static func segmentosDeChrome(hasChat: Bool, hasTerminal: Bool,
                                  hasInfo: Bool) -> [SegmentoDeChrome] {
        var segmentos: [SegmentoDeChrome] = []
        if hasChat {
            segmentos.append(SegmentoDeChrome(id: PaneMode.chat.rawValue, titulo: "Chat", simbolo: "bubble.left"))
        }
        if hasTerminal {
            segmentos.append(SegmentoDeChrome(id: PaneMode.terminal.rawValue, titulo: "Terminal", simbolo: "apple.terminal"))
        }
        if hasInfo {
            segmentos.append(SegmentoDeChrome(id: PaneMode.info.rawValue, titulo: "Info", simbolo: "info.circle"))
        }
        // Um segmento só não é escolha nenhuma — mesma regra de vazio que
        // `selectorSegments` já tinha (ver seu comentário e `SessionDetailPane`,
        // que só checava `isEmpty`).
        return segmentos.count > 1 ? segmentos : []
    }

    /// [12/08/2026] O modo que esta seleção deve MOSTRAR agora, a cada
    /// render — não confundir com `entryPaneMode`, que só decide onde uma aba
    /// NOVA abre. Função identidade no caso comum: se `modo` (o modo GUARDADO
    /// da aba, hoje `nav.paneMode`) já é possível nesta seleção, devolve ele
    /// mesmo sem tocar em nada.
    ///
    /// Existe porque, com abas (G6), N `SessionDetailPane` ficam montados ao
    /// mesmo tempo — decisão #19, é o que preserva a rolagem do chat e o
    /// espelho do tmux — e o modo guardado de UMA aba pode não existir na
    /// seleção de OUTRA: uma aba de chat puro força `.chat`; a aba ao vivo
    /// que estava em `.terminal` continua guardando `.chat` quando volta ao
    /// foco, e `.chat` não existe numa entrada ao vivo. Sem esta função o
    /// pane renderiza os três `if`/`opacity` de `SessionDetailPane.body` com
    /// `showsChat`/`showsTerminal`/`showsInfo` todos `false` — TELA EM
    /// BRANCO. Chamar `modoValido` na hora de decidir `showsChat` etc. (o
    /// agente seguinte faz essa ligação) torna esse branco impossível por
    /// construção: o valor usado pra renderizar nunca é o guardado bruto,
    /// é sempre ele passado por aqui.
    ///
    /// Quando o modo pedido NÃO é possível, cai no PRIMEIRO segmento de
    /// `selectorSegments` — não num valor fixo escolhido à mão. As duas
    /// funções leem os mesmos três "tem/não tem" (ver o comentário de
    /// `selectorSegments` sobre o par) e concordar por construção é o que
    /// garante que o seletor do topo sempre abre com ALGO marcado: o modo que
    /// a view escolhe pra mostrar é, por definição, um dos segmentos que ela
    /// oferece. Quando `selectorSegments` vem vazia (sessão fora do tmux, só
    /// chat — nada pra alternar) não há "primeiro segmento": o único modo
    /// possível já está determinado pelos próprios `hasChat`/`hasTerminal`/
    /// `hasInfo`, então é ele que devolvemos.
    ///
    /// Por que não reusar `entryPaneMode` aqui em vez de duplicar a ideia de
    /// "cair pro seletor"? Porque são duas perguntas diferentes.
    /// `entryPaneMode` responde "onde uma aba NOVA deve abrir" e por isso
    /// força `.terminal` toda vez que `hasInfo` — mesmo quando o modo GUARDADO
    /// já era `.terminal` ou `.info` e continua perfeitamente válido.
    /// Chamar `entryPaneMode` a cada render prenderia toda aba ao vivo pra
    /// sempre em `.terminal`: o ✕ do terminal (que leva pra `.info`) e o
    /// segmento "Info" do seletor nunca teriam efeito, porque no próximo
    /// render a "correção" reverteria os dois de volta. `modoValido` só age
    /// quando o modo guardado é IMPOSSÍVEL nesta seleção — nunca quando ele é
    /// só "diferente do padrão de entrada".
    static func modoValido(_ modo: PaneMode, hasChat: Bool, hasTerminal: Bool,
                           hasInfo: Bool) -> PaneMode {
        let segments = selectorSegments(hasChat: hasChat, hasTerminal: hasTerminal, hasInfo: hasInfo)
        // "Possível" é definido pelos SEGMENTOS, não por reler hasChat/
        // hasTerminal/hasInfo direto: `selectorSegments` já tem prioridade
        // sobre a combinação deles (info bate chat — ver seu comentário), e
        // uma checagem independente por flag divergiria dela bem aqui, na
        // combinação (impossível na prática, mas não impedida pelos tipos)
        // de ter chat E info ao mesmo tempo. Ler o mesmo lugar que
        // `selectorSegments` lê é o que faz as duas concordarem por
        // construção em vez de por sorte.
        if segments.contains(where: { $0.mode == modo }) { return modo }
        if let primeiro = segments.first { return primeiro.mode }

        // `selectorSegments` vem vazia quando só existe UM modo possível —
        // nada pra alternar, então nenhum segmento entra no seletor (ver o
        // comentário de `selectorSegments`). O "tem/não tem" já entrega, sem
        // ambiguidade, qual é esse único modo: sessão fora do tmux só tem
        // chat; a sessão-só-terminal (hipotética, sem chat e sem info) só tem
        // terminal.
        if hasChat { return .chat }
        if hasTerminal { return .terminal }
        return .info
    }

    /// Único título de navegação do pane, computado a partir de `showsChat` —
    /// a fonte de verdade que substitui os dois `.navigationTitle` que
    /// disputavam a mesma barra quando `SessionDetailView` e
    /// `TerminalMirrorView` ficavam montadas juntas (ver
    /// `OwnedNavigationTitle.swift`). Correto por construção: não depende de
    /// quem "vence" a composição de preference keys concorrentes.
    ///
    /// `chatTitle`/`terminalTitle` já vêm resolvidos (apelido local incluso)
    /// — esta função só decide QUAL dos dois mostrar. Quando o lado
    /// preferido por `showsChat` não existe (seleção só tem um dos dois
    /// painéis — ver `modoValido`, [12/08/2026] nome atual desta referência,
    /// antes apontava pra uma função que nunca chegou a existir com este
    /// nome), cai pro que houver; `""` só no caso, teoricamente inatingível
    /// em uso normal, de nenhum dos dois existir.
    static func paneTitle(showsChat: Bool, chatTitle: String?, terminalTitle: String?) -> String {
        if showsChat, let chatTitle { return chatTitle }
        if !showsChat, let terminalTitle { return terminalTitle }
        return chatTitle ?? terminalTitle ?? ""
    }

    /// Resolve QUAL título de chat entra em `paneTitle`: o ao vivo (subido
    /// via `LiveChatTitleKey`, que acompanha `session_updated`/`snapshot`)
    /// quando presente, senão o fallback estático calculado a partir do
    /// snapshot congelado de `nav.selection`.
    ///
    /// Existe porque `SessionDetailPane.session` vem de `nav.selection` —
    /// congelado de propósito (só reatribuído no toque numa linha ou
    /// deep-link, pra não remontar o pane a cada campo que muda) — enquanto
    /// `SessionDetailViewModel.session` é atualizado ao vivo e o hub PODE
    /// mudar `Session.title` depois da criação (`Registry.Reclaim`). Sem
    /// preferir o ao vivo aqui, o título do chat no iPad ficaria preso no
    /// valor de quando a sessão foi selecionada — regressão em relação ao
    /// iPhone, que sempre leu o título ao vivo direto.
    static func resolvedChatTitle(live: String?, fallback: String?) -> String? {
        live ?? fallback
    }
}
