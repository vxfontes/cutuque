import Foundation

enum TipoDeAba: String, Codable {
    case live, chat, board, maquina, arquivado
}

/// Identidade da aba, e a única coisa que vai pro disco (G4). Deliberadamente
/// pequena e `Codable`: guardar `Session`/`Machine` inteiros no `@AppStorage`
/// congelaria dados que envelhecem, e a reconciliação da G4 depende de a chave
/// ser só um endereço.
///
/// `machine` faz parte da identidade porque grupo de tmux com o mesmo nome pode
/// existir em duas máquinas — é o que `identidade-pane-ao-vivo` separou.
struct ChaveDeAba: Hashable, Codable {
    let tipo: TipoDeAba
    let machine: String
    let alvo: String

    init(tipo: TipoDeAba, machine: String = "", alvo: String = "") {
        self.tipo = tipo
        self.machine = machine
        self.alvo = alvo
    }

    static let board = ChaveDeAba(tipo: .board)
    static func maquina(_ nome: String) -> ChaveDeAba { .init(tipo: .maquina, alvo: nome) }
    static func arquivado(_ id: String) -> ChaveDeAba { .init(tipo: .arquivado, alvo: id) }

    static func para(_ selection: DetailSelection) -> ChaveDeAba {
        switch selection {
        case .live(let e):    return .init(tipo: .live, machine: e.machine, alvo: e.paneTarget)
        case .session(let s): return .init(tipo: .chat, machine: s.machine, alvo: s.id)
        }
    }
}

/// O que a aba mostra. `pendente` e `morta` existem por causa da persistência
/// (D2): uma aba restaurada do disco não recria pane nenhum — ela nasce
/// `pendente` e a reconciliação a resolve em conteúdo de verdade ou em `morta`,
/// que é um **aviso**, nunca uma tentativa de ressuscitar.
enum TabConteudo: Equatable {
    case sessao(DetailSelection)
    case board
    case maquina(Machine)
    case arquivado(BoardTask)
    case pendente
    case morta
}

/// `passagem` é a aba de preview do VS Code: existe no máximo uma, e a próxima
/// coisa aberta toma o lugar dela. `fixa` é ortogonal (G3) — protege de "fechar
/// outras"/"fechar todas".
enum EstiloDeAba {
    case passagem, normal
}

struct AbaAberta: Identifiable, Equatable {
    let chave: ChaveDeAba
    var titulo: String
    var estilo: EstiloDeAba
    var fixa: Bool
    var conteudo: TabConteudo
    /// Contador monotônico de foco, não relógio: dá MRU testável sem injetar
    /// tempo (G2 usa isto para decidir quem dorme).
    var ordemDeFoco: Int

    var id: ChaveDeAba { chave }
}

struct OpenTabs: Equatable {
    private(set) var abas: [AbaAberta] = []
    private(set) var selecionada: ChaveDeAba?
    private var contadorDeFoco = 0

    // MARK: abrir e selecionar

    mutating func abrir(chave: ChaveDeAba, titulo: String, conteudo: TabConteudo,
                        estilo: EstiloDeAba = .passagem) {
        contadorDeFoco += 1

        if let i = abas.firstIndex(where: { $0.chave == chave }) {
            // Já aberta: foca, atualiza o título e PROMOVE. Nunca duplica, e
            // nunca rebaixa um conteúdo resolvido de volta a `pendente`.
            abas[i].titulo = titulo
            abas[i].estilo = .normal
            abas[i].ordemDeFoco = contadorDeFoco
            if conteudo != .pendente { abas[i].conteudo = conteudo }
            selecionada = chave
            return
        }

        if estilo == .passagem, let i = abas.firstIndex(where: { $0.estilo == .passagem && !$0.fixa }) {
            abas.remove(at: i)
        }

        abas.append(AbaAberta(chave: chave, titulo: titulo, estilo: estilo,
                              fixa: false, conteudo: conteudo, ordemDeFoco: contadorDeFoco))
        selecionada = chave
    }

    mutating func selecionar(_ chave: ChaveDeAba) {
        guard let i = abas.firstIndex(where: { $0.chave == chave }) else { return }
        contadorDeFoco += 1
        abas[i].ordemDeFoco = contadorDeFoco
        selecionada = chave
    }

    func aba(_ chave: ChaveDeAba) -> AbaAberta? {
        abas.first { $0.chave == chave }
    }

    // MARK: teto de vivas (G2)

    /// Teto de painéis vivos ao mesmo tempo (D3). O número saiu da conversa —
    /// "rola, 6 vivas + dormindo" — e existe porque cada painel vivo custa um
    /// `window-size manual` no tmux do outro lado, não só memória do app.
    static let maxVivas = 6

    /// As `maxVivas` abas mais recentemente focadas. MRU, não ordem da barra:
    /// dormir tem de seguir o uso, senão a aba da esquerda morreria sempre.
    var vivas: [ChaveDeAba] {
        abas.sorted { $0.ordemDeFoco > $1.ordemDeFoco }
            .prefix(Self.maxVivas)
            .map(\.chave)
    }

    /// O estado do painel desta aba. Este método é a ÚNICA fonte do estado que
    /// a `TerminalMirrorView` recebe (Task D1) — nada de View decidindo por conta.
    func estado(de chave: ChaveDeAba) -> TerminalPaneState {
        guard abas.contains(where: { $0.chave == chave }) else { return .liberado }
        if chave == selecionada { return .ativo }
        return vivas.contains(chave) ? .suspenso : .liberado
    }

    // MARK: fixar, fechar, fechar outras, fechar todas (G3)

    mutating func fixar(_ chave: ChaveDeAba) {
        guard let i = abas.firstIndex(where: { $0.chave == chave }) else { return }
        abas[i].fixa = true
        abas[i].estilo = .normal
    }

    mutating func desafixar(_ chave: ChaveDeAba) {
        guard let i = abas.firstIndex(where: { $0.chave == chave }) else { return }
        abas[i].fixa = false
    }

    mutating func fechar(_ chave: ChaveDeAba) {
        guard let i = abas.firstIndex(where: { $0.chave == chave }) else { return }
        let eraAEscolhida = selecionada == chave
        abas.remove(at: i)
        guard eraAEscolhida else { return }
        // Vizinha da esquerda; sem esquerda, a da direita; sem nenhuma, nada
        // escolhido (painel vazio é estado legítimo).
        let vizinha = i > 0 ? abas[i - 1] : (i < abas.count ? abas[i] : nil)
        if let vizinha {
            selecionar(vizinha.chave)
        } else {
            selecionada = nil
        }
    }

    mutating func fecharOutras(_ chave: ChaveDeAba) {
        abas.removeAll { $0.chave != chave && !$0.fixa }
        if abas.contains(where: { $0.chave == chave }) { selecionar(chave) }
    }

    mutating func fecharTodas() {
        abas.removeAll { !$0.fixa }
        if let primeira = abas.first {
            selecionar(primeira.chave)
        } else {
            selecionada = nil
        }
    }
}
