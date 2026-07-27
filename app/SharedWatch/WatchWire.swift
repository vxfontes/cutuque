import Foundation

// Contrato do WatchConnectivity entre o iPhone e o Apple Watch.
//
// Por que este arquivo existe: o dicionário do `sendMessage` era montado no
// iPhone (`PhoneWatchRelay`) e lido no relógio (`WatchConnector`) por dois
// trechos de código independentes, cada um com suas chaves em string solta.
// Qualquer divergência entre os dois só aparecia em runtime, no pulso, sem
// mensagem. Agora os dois lados usam os mesmos tipos daqui.
//
// Regra ao mexer: nada de `import SwiftUI`, `WatchKit` ou `WatchConnectivity`
// neste arquivo. Ele é compilado no alvo iOS *e* no watchOS, e é o único
// pedaço da conversa iPhone↔Watch que a suíte de testes (iOS) consegue ver.

// MARK: - Sessão

/// Uma opção de resposta de uma pergunta de seleção, resumida para o pulso.
struct WatchQuestionOption: Identifiable, Equatable, Hashable {
    let label: String
    let description: String
    var id: String { label }

    init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

/// Uma pergunta de seleção pendente (única ou múltipla), resumida para o pulso.
struct WatchQuestion: Identifiable, Equatable, Hashable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [WatchQuestionOption]
    var id: String { question }

    init(question: String, header: String = "", multiSelect: Bool = false, options: [WatchQuestionOption] = []) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// Uma sessão que precisa de você, resumida para o pulso.
struct WatchSession: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    /// Máquina e agente (ex.: "macbook", "claude") — o pulso mostra em uma
    /// linha discreta pra você saber ONDE a coisa travou sem abrir o iPhone.
    let machine: String
    let agent: String
    let prompt: String
    let hasPane: Bool // true = roda no tmux (só dá pra responder pelo terminal)
    /// Sessão externa (hook/tmux de terceiro): o hub não controla o gate dela, então
    /// o pulso a trata como read-only (sem aprovar/negar/responder).
    let isExternal: Bool
    /// Perguntas de seleção pendentes (AskUserQuestion). Vazio = pedido comum
    /// sim/não (aprovar/negar como antes).
    let questions: [WatchQuestion]

    init(id: String,
         title: String,
         machine: String = "",
         agent: String = "",
         prompt: String = "",
         hasPane: Bool = false,
         isExternal: Bool = false,
         questions: [WatchQuestion] = []) {
        self.id = id
        self.title = title
        self.machine = machine
        self.agent = agent
        self.prompt = prompt
        self.hasPane = hasPane
        self.isExternal = isExternal
        self.questions = questions
    }

    /// "macbook · claude". Vazio se o hub não mandou nenhum dos dois.
    var origin: String {
        [machine, agent].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Panorama das outras sessões

/// Quantas sessões existem em cada estado ALÉM das que precisam de você.
/// Serve pra tela vazia dizer "Tudo em dia · 3 rodando" em vez de só sugerir
/// que não há nada acontecendo.
struct WatchOverview: Equatable {
    var running = 0
    var done = 0
    var error = 0
    var idle = 0

    var isEmpty: Bool { running == 0 && done == 0 && error == 0 && idle == 0 }

    /// Resumo curto: no máximo dois itens, em ordem de urgência
    /// (rodando → falhou → concluída → ociosa). O mostrador é estreito;
    /// listar os quatro estados vira uma linha que ninguém lê.
    var summary: String {
        let parts: [(n: Int, one: String, many: String)] = [
            (running, "rodando", "rodando"),
            (error, "falhou", "falharam"),
            (done, "concluída", "concluídas"),
            (idle, "ociosa", "ociosas"),
        ]
        return parts
            .filter { $0.n > 0 }
            .prefix(2)
            .map { "\($0.n) \($0.n == 1 ? $0.one : $0.many)" }
            .joined(separator: " · ")
    }
}

// MARK: - Resposta do iPhone

/// A resposta do iPhone ao pedido `needsYou`.
///
/// O ponto de existir um tipo com `init?`: uma resposta MALFORMADA (sem a
/// chave `sessions`) tem que ser distinguível de uma resposta legítima com
/// lista vazia. Antes as duas viravam `[]` e o pulso escrevia "Tudo em dia"
/// nas duas — dizendo que estava tudo certo justamente quando não estava.
struct WatchNeedsYouReply: Equatable {
    let sessions: [WatchSession]
    let overview: WatchOverview

    init(sessions: [WatchSession], overview: WatchOverview = WatchOverview()) {
        self.sessions = sessions
        self.overview = overview
    }
}

// MARK: - Serialização (dicionário do sendMessage)

/// Chaves do wire, em um lugar só.
enum WatchWireKey {
    static let action = "action"
    static let id = "id"
    static let text = "text"
    static let answers = "answers"
    static let selected = "selected"
    static let ok = "ok"
    static let error = "error"
    static let sessions = "sessions"
    static let counts = "counts"
}

extension WatchQuestionOption {
    var wire: [String: Any] { ["label": label, "description": description] }

    init?(wire: [String: Any]) {
        guard let label = wire["label"] as? String, !label.isEmpty else { return nil }
        self.init(label: label, description: wire["description"] as? String ?? "")
    }
}

extension WatchQuestion {
    var wire: [String: Any] {
        [
            "question": question,
            "header": header,
            "multiSelect": multiSelect,
            "options": options.map(\.wire),
        ]
    }

    init?(wire: [String: Any]) {
        guard let question = wire["question"] as? String, !question.isEmpty else { return nil }
        let rawOptions = wire["options"] as? [[String: Any]] ?? []
        self.init(question: question,
                  header: wire["header"] as? String ?? "",
                  multiSelect: wire["multiSelect"] as? Bool ?? false,
                  options: rawOptions.compactMap(WatchQuestionOption.init(wire:)))
    }
}

extension WatchSession {
    var wire: [String: Any] {
        [
            "id": id,
            "title": title,
            "machine": machine,
            "agent": agent,
            "prompt": prompt,
            "hasPane": hasPane,
            "isExternal": isExternal,
            "questions": questions.map(\.wire),
        ]
    }

    /// Uma sessão sem `id` não dá pra aprovar nem negar — descarta em vez de
    /// virar uma linha morta na lista.
    init?(wire: [String: Any]) {
        guard let id = wire["id"] as? String, !id.isEmpty else { return nil }
        let rawQuestions = wire["questions"] as? [[String: Any]] ?? []
        self.init(id: id,
                  title: (wire["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "sessão",
                  machine: wire["machine"] as? String ?? "",
                  agent: wire["agent"] as? String ?? "",
                  prompt: wire["prompt"] as? String ?? "",
                  hasPane: wire["hasPane"] as? Bool ?? false,
                  isExternal: wire["isExternal"] as? Bool ?? false,
                  questions: rawQuestions.compactMap(WatchQuestion.init(wire:)))
    }
}

extension WatchOverview {
    var wire: [String: Any] {
        ["running": running, "done": done, "error": error, "idle": idle]
    }

    init(wire: [String: Any]) {
        self.init(running: wire["running"] as? Int ?? 0,
                  done: wire["done"] as? Int ?? 0,
                  error: wire["error"] as? Int ?? 0,
                  idle: wire["idle"] as? Int ?? 0)
    }
}

extension WatchNeedsYouReply {
    var wire: [String: Any] {
        [WatchWireKey.sessions: sessions.map(\.wire), WatchWireKey.counts: overview.wire]
    }

    /// `nil` quando a resposta não traz a chave `sessions` — resposta de erro
    /// do iPhone, resposta de outra ação, ou lixo. Nunca confunda isso com
    /// "não há nada precisando de você".
    init?(wire: [String: Any]) {
        guard let raw = wire[WatchWireKey.sessions] as? [[String: Any]] else { return nil }
        self.init(sessions: raw.compactMap(WatchSession.init(wire:)),
                  overview: WatchOverview(wire: wire[WatchWireKey.counts] as? [String: Any] ?? [:]))
    }
}

// MARK: - Estado da tela

/// RESULTADO do último pedido ao iPhone.
///
/// Repare que não há um caso "carregando": ter um pedido em voo é ortogonal ao
/// que a tela sabe. Enquanto o auto-refresh trabalha de fundo, o relógio segue
/// mostrando o último resultado — trocar a lista por um "Procurando…" a cada
/// dez segundos é pior que mostrar dado com dez segundos de idade, e o rodapé
/// conta essa idade. "Procurando…" só aparece na primeiríssima carga.
enum WatchLoadPhase: Equatable {
    /// Nunca chegou resposta (app acabou de abrir).
    case inicial
    /// Chegou resposta válida.
    case carregado
    /// O pedido falhou, ou veio uma resposta que não dá pra ler.
    case falhou(String)
}

/// O que a tela principal mostra. Cada caso é uma tela diferente — era isso
/// que faltava: antes, "nunca carreguei", "falhou" e "não há nada" caíam todos
/// no mesmo "Tudo em dia".
enum WatchScreen: Equatable {
    case carregando
    case foraDeAlcance
    case falhou(String)
    case tudoEmDia(WatchOverview)
    case lista([WatchSession])
}

enum WatchScreenState {
    /// Decide a tela. Função pura de propósito — é o único lugar onde essa
    /// escolha mora, e a suíte de testes verifica cada ramo.
    ///
    /// Ordem importa: uma lista já carregada continua na tela mesmo que o
    /// refresh seguinte falhe ou o iPhone se afaste. Perder o que já se sabe
    /// (e que ainda dá pra aprovar) é pior que ficar um pouco desatualizado —
    /// o rodapé conta a idade do dado.
    static func screen(phase: WatchLoadPhase,
                       reachable: Bool,
                       sessions: [WatchSession],
                       overview: WatchOverview) -> WatchScreen {
        if !sessions.isEmpty { return .lista(sessions) }
        switch phase {
        case .inicial:
            // Primeira carga. Se o iPhone já está fora de alcance, fale disso
            // em vez de girar pra sempre.
            return reachable ? .carregando : .foraDeAlcance
        case .falhou(let motivo):
            // Fora de alcance é mais acionável ("chegue perto do iPhone") que
            // o texto do erro, então tem precedência.
            return reachable ? .falhou(motivo) : .foraDeAlcance
        case .carregado:
            return reachable || !overview.isEmpty ? .tudoEmDia(overview) : .foraDeAlcance
        }
    }

    /// Rodapé da lista: idade do dado, ou o erro do último refresh quando a
    /// lista antiga ainda está na tela.
    static func footer(erro: String?, idade: TimeInterval?) -> String? {
        if let erro { return erro }
        guard let idade else { return nil }
        return "atualizado \(ago(idade))"
    }

    /// "agora" / "há 12 s" / "há 3 min" / "há 2 h".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 5 { return "agora" }
        if s < 60 { return "há \(Int(s)) s" }
        if s < 3600 { return "há \(Int(s / 60)) min" }
        return "há \(Int(s / 3600)) h"
    }
}
