import Foundation

/// Filtro por máquina da tela inicial (a faixa de chips acima da lista).
///
/// Lógica pura fora da View porque é o que dá para testar sem simulador — e
/// porque a parte que erra aqui não é desenhar o chip, é a CONTAGEM: a lista
/// mostra a mesma sessão em seções diferentes conforme ela esteja viva no tmux
/// ou não, e um chip que conta o registry cru mente em duas direções ao mesmo
/// tempo (soma a sessão espelhada em "Ao vivo" duas vezes e ignora o pane vivo
/// que ainda não virou sessão no registry).
enum FiltroDeMaquinas {
    /// Escolha "Todas" — guardada como string vazia porque o valor mora num
    /// `@AppStorage`, e string vazia é o default de fábrica dele.
    static let todas = ""

    /// As máquinas que viram chip, na ordem em que aparecem.
    ///
    /// `conhecidas` (as que o poll de vivas conhece) vem primeiro e NA ORDEM
    /// DELA, para o chip não pular de lugar a cada passada; máquina que só
    /// aparece nas sessões (hub antigo, sessão de uma máquina que saiu do
    /// `targets`) entra depois, em ordem alfabética, para não sumir do filtro.
    static func maquinas(conhecidas: [String], sessoes: [Session], vivas: [LiveEntry]) -> [String] {
        var ordenadas: [String] = []
        var vistas = Set<String>()
        for nome in conhecidas where !nome.isEmpty && !vistas.contains(nome) {
            ordenadas.append(nome)
            vistas.insert(nome)
        }
        let extras = (sessoes.map(\.machine) + vivas.map(\.machine))
            .filter { !$0.isEmpty && !vistas.contains($0) }
        for nome in Set(extras).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            ordenadas.append(nome)
            vistas.insert(nome)
        }
        return ordenadas
    }

    /// Quantas LINHAS a lista mostra por máquina — não quantas sessões o hub
    /// tem. Reproduz a dedup das seções: uma sessão que já aparece como pane
    /// vivo na seção "Ao vivo" não conta de novo, e um pane vivo que já aparece
    /// em "Precisa de você" não conta pela entrada ao vivo.
    static func contagemPorMaquina(sessoes: [Session], vivas: [LiveEntry]) -> [String: Int] {
        let panesVivos = Set(vivas.map(\.paneTarget))
        let panesDeNeedsYou = Set(sessoes.filter { $0.state == .needsYou }.compactMap(\.tmuxTarget))
        var contagem: [String: Int] = [:]
        for sessao in sessoes {
            // A sessão espelhada em "Ao vivo" (não é needs_you e o pane está
            // vivo) sai da seção "Sessões" — então também sai da contagem.
            if sessao.state != .needsYou, let alvo = sessao.tmuxTarget, panesVivos.contains(alvo) { continue }
            contagem[sessao.machine, default: 0] += 1
        }
        for viva in vivas where !panesDeNeedsYou.contains(viva.paneTarget) {
            contagem[viva.machine, default: 0] += 1
        }
        return contagem
    }

    /// Total de linhas (o número do chip "Todas").
    static func total(_ contagem: [String: Int]) -> Int {
        contagem.values.reduce(0, +)
    }

    static func sessoes(_ lista: [Session], maquina: String) -> [Session] {
        maquina.isEmpty ? lista : lista.filter { $0.machine == maquina }
    }

    static func vivas(_ lista: [LiveEntry], maquina: String) -> [LiveEntry] {
        maquina.isEmpty ? lista : lista.filter { $0.machine == maquina }
    }

    /// A escolha ainda faz sentido? Máquina que saiu do hub deixaria a tela
    /// vazia para sempre (e o `@AppStorage` guarda isso entre aberturas), então
    /// vira "Todas".
    ///
    /// Lista vazia NÃO invalida nada: é o estado normal enquanto o primeiro
    /// poll não voltou, e zerar ali apagaria a escolha de quem só abriu o app.
    static func escolhaValida(_ escolha: String, entre maquinas: [String]) -> String {
        guard !escolha.isEmpty, !maquinas.isEmpty else { return escolha }
        return maquinas.contains(escolha) ? escolha : todas
    }
}
