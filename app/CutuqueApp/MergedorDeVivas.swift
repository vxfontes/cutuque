/// Funde as panes ao vivo máquina por máquina, à medida que cada uma responde.
///
/// [13/08/2026] Existe porque `refreshLive` buscava sequencialmente e só
/// publicava no fim: medido contra produção, 11,28 s até a lista pintar, dos
/// quais 10,016 s eram o `ConnectTimeout=10` do ssh do hub numa máquina
/// desligada (`windows`). As 7 panes do `macbook` chegavam em 1 s e
/// **esperavam** o `windows`. Sem estado de carregando, isso é indistinguível
/// de "não tem nada rodando" — daí "sempre preciso puxar pra baixo pra dar o
/// refresh" (apontamento da Vanessa).
///
/// A regra de "limpa só depois de 2 leituras vazias seguidas" (evita o "some e
/// volta" de um hiccup transitório de SSH) era GLOBAL e aqui é POR MÁQUINA:
/// global, a máquina desligada (sempre 0 panes) incrementaria o MESMO contador
/// que o `macbook` usa, e ao completar as 2 leituras vazias dela apagaria as
/// vivas do `macbook` — que respondia normalmente. Por máquina, uma leitura
/// vazia do `windows` nunca afeta o contador do `macbook`.
struct MergedorDeVivas {
    static let vaziosParaLimpar = 2

    private var ordem: [String]
    private var porMaquina: [String: [LiveEntry]] = [:]
    private var vazios: [String: Int] = [:]

    init(ordem: [String]) { self.ordem = ordem }

    /// Todas as entradas vivas conhecidas, na ordem ESTÁVEL de `ordem` (a de
    /// `/targets`) — nunca na ordem de chegada das respostas, senão a lista
    /// pula de lugar a cada passada conforme quem responde primeiro.
    var entradas: [LiveEntry] { ordem.flatMap { porMaquina[$0] ?? [] } }

    /// Redefine a ordem (nova leitura de `/targets`). Máquina que saiu do
    /// cadastro não deixa fantasma na lista: sem isto, uma máquina desligada e
    /// removida continuaria aparecendo com a última leitura que teve.
    mutating func definirOrdem(_ nova: [String]) {
        ordem = nova
        for chave in porMaquina.keys where !nova.contains(chave) {
            porMaquina[chave] = nil
            vazios[chave] = nil
        }
    }

    /// Funde a resposta de UMA máquina e devolve a lista completa já
    /// atualizada (pronta para publicar em `liveSessions` na hora — é o que
    /// faz cada máquina pintar assim que responde, em vez de esperar as
    /// demais).
    @discardableResult
    mutating func fundir(maquina: String, entradas novas: [LiveEntry]) -> [LiveEntry] {
        if novas.isEmpty {
            let n = (vazios[maquina] ?? 0) + 1
            vazios[maquina] = n
            if n >= Self.vaziosParaLimpar { porMaquina[maquina] = [] }
        } else {
            vazios[maquina] = 0
            porMaquina[maquina] = novas
        }
        // Máquina respondeu fora da ordem conhecida (corrida com `definirOrdem`,
        // ou chamada avulsa de teste): entra no fim em vez de sumir.
        if !ordem.contains(maquina) { ordem.append(maquina) }
        return entradas
    }
}
