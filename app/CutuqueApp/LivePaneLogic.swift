import Foundation

/// Lógica pura das sessões ao vivo. Fora da View porque é o que dá para testar
/// sem simulador — e é onde moram os erros que a tela só mostra depois.
enum LivePaneLogic {
    /// Remoção otimista do "encerrar server": só os panes DAQUELA máquina.
    /// Casar só por socket apagava da tela as linhas da outra máquina quando
    /// duas rodam um grupo de mesmo nome com o mesmo uid.
    static func removendoServer(_ entries: [LiveEntry], machine: String, socket: String) -> [LiveEntry] {
        entries.filter { !($0.machine == machine && $0.paneTarget.hasPrefix(socket + "\t")) }
    }

    /// Socket (parte antes do TAB) do alvo composto de pane "<socket>\t<pane>".
    /// Alvo sem TAB (servidor default, ex.: "%3") não tem socket — devolve "",
    /// não o texto inteiro. Ajuste de 12/08/2026: o `split` sem separador
    /// encontrado devolve o próprio texto como único elemento, e isso derrubava
    /// o agrupamento por grupo (D9) fazendo um pane sem socket virar um grupo
    /// próprio com o nome do pane.
    static func socket(of paneTarget: String) -> String {
        guard let tab = paneTarget.firstIndex(of: "\t") else { return "" }
        return String(paneTarget[..<tab])
    }

    /// Nome legível do grupo = último componente do socket (ex.: "main", "teste").
    /// O grupo É o socket do tmux (-L) — o mesmo identificador que o board usa
    /// como escopo (CUTUQUE_GROUP).
    static func nomeDoGrupo(_ socket: String) -> String {
        (socket as NSString).lastPathComponent
    }
}

/// Um servidor tmux concreto dentro de um grupo: máquina + socket. Existe porque
/// "Encerrar server" é destrutivo e precisa dos dois — o mesmo caminho de socket
/// existe em duas máquinas de mesmo uid.
struct ServidorDoGrupo: Identifiable, Equatable, Hashable {
    let machine: String
    let socket: String
    var id: String { machine + "\t" + socket }
}

/// Um grupo do tmux na lista ao vivo: uma seção, com as máquinas misturadas dentro
/// (D9). Grupo é projeto/contexto — o mesmo identificador que o board usa como
/// escopo (CUTUQUE_GROUP = socket); máquina é detalhe de execução, e vive no ícone
/// de cada linha.
struct GrupoAoVivo: Identifiable, Equatable {
    let grupo: String
    let servers: [ServidorDoGrupo]
    let entries: [LiveEntry]
    var id: String { grupo }
}

extension LivePaneLogic {
    /// Rótulo da ação destrutiva. A máquina entra SEMPRE, mesmo com uma só no grupo:
    /// aqui não vale a economia de ruído do rótulo de seção antigo, porque o custo do
    /// erro é encerrar o server da máquina errada.
    static func rotuloDeEncerrar(_ servidor: ServidorDoGrupo) -> String {
        "Encerrar server no \(servidor.machine)"
    }

    /// Agrupa por NOME do grupo, não por máquina + socket. Antes o agrupamento
    /// incluía a máquina para o "Encerrar server" do cabeçalho não ficar ambíguo;
    /// agora a ambiguidade é resolvida na ação (uma entrada por máquina) em vez de
    /// na seção, que é o que a D9 pede.
    ///
    /// Ordem: grupos por nome e, dentro do grupo, por máquina e depois pelo alvo —
    /// determinística, para a lista não dançar entre polls.
    static func agrupadoPorGrupo(_ entries: [LiveEntry]) -> [GrupoAoVivo] {
        let porGrupo = Dictionary(grouping: entries) { nomeDoGrupo(socket(of: $0.paneTarget)) }
        return porGrupo.keys.sorted().map { grupo in
            let doGrupo = porGrupo[grupo] ?? []
            let servidores = Set(doGrupo.map { ServidorDoGrupo(machine: $0.machine, socket: socket(of: $0.paneTarget)) })
            return GrupoAoVivo(
                grupo: grupo,
                servers: servidores.sorted { $0.id < $1.id },
                entries: doGrupo.sorted { ($0.machine, $0.paneTarget) < ($1.machine, $1.paneTarget) }
            )
        }
    }
}
