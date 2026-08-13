import SwiftUI

// MARK: - Estado da sessão

/// Estados possíveis de uma sessão de agente, conforme contrato do hub.
/// Cada estado tem uma cor associada usada nas bolinhas da lista.
enum SessionState: String, Codable {
    case running    // rodando
    case needsYou   // precisa de você (needs_you no wire)
    case done       // concluído
    case error      // falhou
    case idle       // ocioso

    // O hub usa snake_case no valor (ex.: "needs_you"), então mapeamos manualmente.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running":   self = .running
        case "needs_you": self = .needsYou
        case "done":      self = .done
        case "error":     self = .error
        case "idle":      self = .idle
        default:          self = .idle // desconhecido cai em idle (defensivo)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    /// Valor exato usado no protocolo (snake_case).
    var wireValue: String {
        switch self {
        case .running:  return "running"
        case .needsYou: return "needs_you"
        case .done:     return "done"
        case .error:    return "error"
        case .idle:     return "idle"
        }
    }

    /// Cor da bolinha de estado.
    var color: Color {
        switch self {
        case .running:  return .blue
        case .needsYou: return .orange
        case .done:     return .green
        case .error:    return .red
        case .idle:     return .gray
        }
    }

    /// Rótulo textual em português exibido na lista.
    var label: String {
        switch self {
        case .running:  return "rodando"
        case .needsYou: return "precisa de você"
        case .done:     return "concluído"
        case .error:    return "falhou"
        case .idle:     return "ocioso"
        }
    }
}

/// A cor de um status na tela, considerando a cor de destaque escolhida em
/// Ajustes. Separada de `SessionState.color` porque a de destaque vem do
/// AMBIENTE (`\.corDeDestaque`, ver `AppTheme.swift`) e modelo não lê
/// ambiente — `enum`/`struct` puro não tem `@Environment`.
///
/// `SessionListView` já resolvia isto à mão (`s == .running ? accentColor :
/// s.color`); aqui vira um lugar só, testável fora de View. (13/08/2026)
enum CorDeStatus {
    /// `.running` é o único status que segue a preferência: ele não é
    /// semântico (não é erro, não é sucesso, não é aviso) — é "a coisa está
    /// andando", que é o papel de destaque do app. Os demais (`.needsYou`,
    /// `.done`, `.error`, `.idle`) são semânticos e permanecem literais.
    static func para(_ status: SessionState, destaque: Color) -> Color {
        status == .running ? destaque : status.color
    }
}

// MARK: - Chunks de output (transcrito estilo chat)

/// Tipo de um pedaço de output, conforme o contrato novo do hub.
/// Determina como o chunk é desenhado no transcrito: bolha do usuário,
/// texto do assistente, ou linha discreta de ferramenta/resultado.
enum ChunkKind: Decodable, Equatable {
    case user
    case assistant
    case tool
    case toolResult

    // O hub usa snake_case no valor (ex.: "tool_result"), então mapeamos manualmente.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "user":        self = .user
        case "assistant":   self = .assistant
        case "tool":        self = .tool
        case "tool_result": self = .toolResult
        default:            self = .assistant // desconhecido cai em assistente (defensivo)
        }
    }
}

/// Um pedaço de output do histórico (`GET /sessions/{id}/output`), já
/// classificado por tipo. `id` é só local (não vem do wire) — serve para
/// identidade estável em listas SwiftUI.
struct OutputChunk: Decodable, Identifiable, Equatable {
    let id = UUID()
    let kind: ChunkKind
    let text: String

    private enum CodingKeys: String, CodingKey {
        case kind, text
    }
}

// MARK: - Pergunta de seleção (AskUserQuestion)

/// Uma opção de resposta para uma pergunta de seleção, com rótulo em destaque
/// e descrição opcional em texto corrido.
struct QuestionOption: Codable, Equatable, Hashable, Identifiable {
    let label: String
    let description: String?
    var id: String { label }
}

/// Uma pergunta de seleção pendente (única ou múltipla). Presente no
/// `pending_questions` da sessão quando o pedido pendente NÃO é uma permissão
/// comum sim/não, e sim uma pergunta com opções (ferramenta AskUserQuestion do
/// Claude Code). `header` é curto (≤12 chars, ex.: "Cor"); `question` é o
/// texto exato a devolver em `POST /answer`.
struct PendingQuestion: Codable, Equatable, Hashable, Identifiable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QuestionOption]
    var id: String { question }
}

// MARK: - Sessão

/// Uma sessão de agente reportada pelo hub.
/// Chaves em snake_case são resolvidas via `convertFromSnakeCase` no decoder compartilhado.
struct Session: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let machine: String
    let agent: String
    let title: String
    let state: SessionState
    let createdAt: Date
    let updatedAt: Date
    /// Texto do pedido de permissão/pergunta quando `state == .needsYou`.
    /// Opcional: pode faltar no payload (decode de `pending_prompt` via snake_case).
    let pendingPrompt: String?
    /// Alvo tmux ("<socket>\t<pane>") quando a sessão roda dentro do tmux (veio
    /// de hook com $TMUX). Vazio/nil = sessão local fora do tmux. Permite abrir o
    /// terminal ao vivo exato dessa sessão.
    let pane: String?
    /// True se a sessão NÃO foi lançada pelo app (hook do Claude / adoção). Nessas
    /// o hub não controla o gate de permissão — nada de aprovar/negar; a resposta
    /// é no terminal.
    let external: Bool?
    /// Pasta onde a sessão roda (para a árvore no detalhe/ao-vivo).
    let cwd: String?
    /// Perguntas de seleção pendentes (ferramenta AskUserQuestion), quando o
    /// pedido pendente NÃO é uma permissão comum sim/não. Ausente/nil = pedido
    /// comum (aprovar/negar como antes). 1 a 4 perguntas.
    let pendingQuestions: [PendingQuestion]?

    // pane/external/cwd/pendingQuestions podem faltar em respostas de um hub antigo → default seguro.
    private enum CodingKeys: String, CodingKey {
        case id, machine, agent, title, state, createdAt, updatedAt, pendingPrompt, pane, external, cwd, pendingQuestions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(String.self, forKey: .machine)
        agent = try c.decode(String.self, forKey: .agent)
        title = try c.decode(String.self, forKey: .title)
        state = try c.decode(SessionState.self, forKey: .state)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pendingPrompt = try? c.decode(String.self, forKey: .pendingPrompt)
        pane = try? c.decode(String.self, forKey: .pane)
        external = try? c.decode(Bool.self, forKey: .external)
        cwd = try? c.decode(String.self, forKey: .cwd)
        pendingQuestions = try? c.decode([PendingQuestion].self, forKey: .pendingQuestions)
    }
    /// True quando é uma sessão externa (hook/adoção) — o app NÃO mostra
    /// aprovar/negar (a resposta é no terminal do Mac).
    var isExternal: Bool { external ?? false }

    /// Alvo tmux não-vazio, se a sessão for de terminal ao vivo.
    var tmuxTarget: String? {
        guard let p = pane, !p.isEmpty else { return nil }
        return p
    }
}

// MARK: - Sessão descoberta (acompanhar sessões do Mac)

/// Uma sessão do Claude Code já existente numa máquina, lida de
/// `~/.claude/projects` lá (`GET /machines/{machine}/sessions`), inclusive as
/// não lançadas pelo Cutuque. É "descoberta" (ainda não adotada): ao tocar,
/// o app a adota (registra no hub) e abre para continuar a conversa.
struct DiscoveredSession: Decodable, Identifiable, Equatable, Hashable {
    let id: String        // = session_id (nome do arquivo .jsonl)
    let cwd: String       // pasta onde a sessão roda
    let title: String     // primeira mensagem do usuário
    let last: String      // última mensagem do usuário (preview)
    let count: Int        // nº de mensagens do usuário (preview)
    let modified: Int64   // mtime do transcript (epoch em segundos)
    let state: String     // "running"|"waiting"|"idle" (só panes vivos do tmux; lido do terminal)
    let agent: String     // "claude-code"|"codex" (qual agente gerou a sessão)
    /// "shell" = pane sem agente (D11). Vazio = pane de agente ou sessão que não vem
    /// do tmux. Campo novo → hub antigo não manda → default seguro.
    let kind: String

    /// Instante da última atividade, derivado do mtime.
    var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }

    /// Terminal livre: aparece na lista marcado, senão o que o formulário criou
    /// desaparece no refresh seguinte.
    var ehShell: Bool { kind == "shell" }

    /// Último componente da pasta (ex.: "personal") para rótulo compacto.
    var folderName: String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return trimmed.split(separator: "/").last.map(String.init) ?? cwd
    }

    /// Componentes da pasta (para a "árvore" no preview), sem o "/" inicial.
    var pathComponents: [String] {
        cwd.split(separator: "/").map(String.init)
    }

    // Campos novos podem faltar em respostas de um hub antigo → default seguro.
    private enum CodingKeys: String, CodingKey { case id, cwd, title, last, count, modified, state, agent, kind }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decode(String.self, forKey: .title)
        last = (try? c.decode(String.self, forKey: .last)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        modified = (try? c.decode(Int64.self, forKey: .modified)) ?? 0
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        // Hub antigo não manda agent → assume claude-code (legado).
        agent = (try? c.decode(String.self, forKey: .agent)) ?? "claude-code"
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
    }

    /// Init direto (para sintetizar uma entrada viva a partir de uma sessão do
    /// registry que tem um pane tmux).
    init(id: String, cwd: String, title: String, last: String = "", count: Int = 0, modified: Int64 = 0, state: String = "", agent: String = "claude-code", kind: String = "") {
        self.id = id; self.cwd = cwd; self.title = title
        self.last = last; self.count = count; self.modified = modified; self.state = state; self.agent = agent
        self.kind = kind
    }
}

// MARK: - Histórico (event-log persistido)

/// Um evento na linha do tempo de uma sessão passada (GET /history/{id}/events).
struct HistoryEvent: Decodable, Identifiable, Hashable {
    let seq: Int64
    let at: Date
    let type: String      // session_started|output_chunk|needs_input|user_responded|finished|errored
    let kind: String      // user|assistant|tool|tool_result (só em output_chunk)
    let data: String
    var id: Int64 { seq }

    private enum CodingKeys: String, CodingKey { case seq, at, type, kind, data }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date(timeIntervalSince1970: 0)
        type = try c.decode(String.self, forKey: .type)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        data = (try? c.decode(String.self, forKey: .data)) ?? ""
    }
}

// MARK: - Seletor de pastas

/// Uma subpasta no Mac (item do seletor de pastas ao criar uma sessão).
struct DirEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
    /// Pasta oculta (começa com ".") — escondida por padrão no seletor.
    var isHidden: Bool { name.hasPrefix(".") }
}

/// Conteúdo navegável de um diretório no Mac: caminho atual, pai (subir), subpastas.
struct DirListing: Decodable {
    let path: String
    let parent: String
    let dirs: [DirEntry]
}

// MARK: - Aba Máquinas

/// Uma máquina que o hub conhece. Vem do `CUTUQUE_SSH_TARGETS` (source "env") ou
/// é a própria máquina do hub (source "local"). `GET /machines`.
struct Machine: Decodable, Identifiable, Hashable {
    let name: String
    /// Destino ssh: alias do `~/.ssh/config` ou `user@host`. Vem SEMPRE do hub
    /// (derivado de `username@host` pela identidade) — é só exibição.
    let dest: String
    let port: Int
    let source: String
    /// Impressão digital da chave do host, confirmada no cadastro (TOFU).
    /// Ausente = ainda não confiada: o hub se recusa a conectar.
    let hostFingerprint: String?
    /// Hostname/IP puro (sem usuário) — desde o redesenho no modelo Termius,
    /// host e identidade são objetos separados. Ausente em máquinas do
    /// `hub.env` (só têm `dest` pronto).
    let host: String?
    /// Nome da identidade usada pra conectar — reutilizável entre hosts.
    let identity: String?
    /// SO detectado no cadastro ("Darwin", "Ubuntu 22.04"...). Vazio até o
    /// `/detect-os` rodar, ou pra sempre se ele falhar (não é fatal: só o ícone).
    let os: String?
    /// Id do tema de terminal escolhido pra este host; "" ou nil = padrão.
    let theme: String?
    /// Id do ícone escolhido À MÃO; "" ou nil = automático (pelo `os`). Existe
    /// porque a detecção pode falhar pra sempre num host, e sem isso ele ficaria
    /// no ícone genérico sem recurso.
    let icon: String?
    var id: String { name }

    /// A máquina onde o próprio hub roda — não tem ssh no meio.
    var isLocal: Bool { source == "local" }

    /// Cadastrada aqui pelo app — só essas dá para editar ou remover. As do
    /// `hub.env` (e a local) pertencem ao hub.
    var isEditable: Bool { source == "app" }

    /// Cadastro do app que ainda não teve a impressão digital confirmada. Fica
    /// na lista, mas não conecta: falta a usuária conferir a chave do host.
    var needsTrust: Bool { isEditable && (hostFingerprint ?? "").isEmpty }

    /// Destino como a lista mostra. A porta padrão não polui; uma diferente é o
    /// que distingue duas entradas para o mesmo host.
    var displayDest: String {
        if isLocal { return "aqui mesmo" }
        return port == 22 || port == 0 ? dest : "\(dest):\(port)"
    }

    /// Ícone pelo SO detectado (`/detect-os`) — substitui qualquer palpite por
    /// nome/dest por um fato que o hub confirmou de verdade.
    ///
    /// A ORDEM é de propósito: distro ganha do Windows. Um host WSL2 responde o
    /// `PRETTY_NAME` do `/etc/os-release` ("Ubuntu 22.04.3 LTS") — sem a palavra
    /// "WSL", porque quem atende o ssh é o userland Ubuntu —, e mesmo pelo
    /// fallback do `uname -sr` vem "Linux ...-microsoft-standard-WSL2", que
    /// também casa em "linux" primeiro. O ramo do "pc" é pro OpenSSH nativo do
    /// Windows. Reordenar isso trocaria o ícone de todo WSL por um PC.
    var osIcon: String { Machine.osIcon(para: os) }

    static func osIcon(para os: String?) -> String {
        let s = (os ?? "").lowercased()
        if s.contains("darwin") || s.contains("macos") { return "apple.logo" }
        if s.contains("ubuntu") || s.contains("debian") || s.contains("linux")
            || s.contains("alpine") || s.contains("arch") || s.contains("fedora") { return "terminal" }
        if s.contains("windows") || s.contains("wsl") { return "pc" }
        return "desktopcomputer" // vazio/desconhecido
    }

    /// Ícone que a lista e a barra realmente mostram: a escolha à mão vence o SO
    /// detectado, que vence o genérico.
    var displayIcon: String { MachineIcon.symbol(escolhido: icon, os: os) }
}

extension Notification.Name {
    /// Alguma máquina mudou no hub por uma tela que não é a lista (hoje: a
    /// aparência, trocada no painel de detalhe). Existe porque no iPad a lista
    /// fica visível ao lado do painel — ela não "reaparece" para recarregar
    /// sozinha, e o caminho direto (reescrever a máquina selecionada) destruiria
    /// o painel e mataria o `ssh` vivo.
    static let maquinasMudaram = Notification.Name("cutuque.maquinasMudaram")
}

/// Ícones que a usuária pode escolher à mão para uma máquina.
///
/// O hub guarda só o `rawValue` e valida a FORMA, não a lista — quem conhece os
/// ícones é o app. Por isso a leitura passa por aqui (`MachineIcon(rawValue:)`) e
/// nunca joga a string do hub direto num `Image(systemName:)`: id desconhecido
/// renderizaria vazio, e cair no automático é melhor que um buraco na tela.
///
/// Ausência de caso é de propósito: "automático" não é um ícone, é a falta de
/// escolha, e mora no `nil`/`""` do `machine.icon`.
enum MachineIcon: String, CaseIterable, Identifiable {
    case apple, linux, windows, server, laptop, desktop, cloud, board, disk

    var id: String { rawValue }

    /// A precedência do ícone num lugar só: escolha à mão vence SO detectado, que
    /// vence o genérico. Id desconhecido (escolha feita por um app mais novo) cai
    /// no automático em vez de virar quadrado vazio na tela.
    ///
    /// Existe como `static` porque a tela de aparência tem a escolha em `@State` —
    /// a `Machine` que ela recebeu já está desatualizada no momento em que a
    /// usuária toca num ícone, e duplicar a regra lá era como as duas divergiriam.
    static func symbol(escolhido: String?, os: String?) -> String {
        if let escolhido, let manual = MachineIcon(rawValue: escolhido) {
            return manual.symbol
        }
        return Machine.osIcon(para: os)
    }

    var symbol: String {
        switch self {
        case .apple:   return "apple.logo"
        case .linux:   return "terminal"
        case .windows: return "pc"
        case .server:  return "server.rack"
        case .laptop:  return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .cloud:   return "cloud"
        case .board:   return "cpu"
        case .disk:    return "externaldrive"
        }
    }

    var label: String {
        switch self {
        case .apple:   return "Maçã"
        case .linux:   return "Linux"
        case .windows: return "Windows"
        case .server:  return "Servidor"
        case .laptop:  return "Notebook"
        case .desktop: return "Desktop"
        case .cloud:   return "Nuvem"
        case .board:   return "Plaquinha"
        case .disk:    return "Disco"
        }
    }
}

/// Resposta do cadastro de uma máquina nova (`POST /machines`).
///
/// A chave PRIVADA não vem aqui — nem em lugar nenhum. Ela nasce no hub e não
/// sai de lá; o app recebe só a pública, para a usuária instalar no destino.
///
/// `fingerprint` vem solto, fora da máquina, porque nesse ponto ele ainda NÃO
/// está confiado: é o que ela tem que conferir antes do `POST /trust`.
struct MachineCreated: Decodable {
    let machine: Machine
    let publicKey: String
    let fingerprint: String
}

/// Envelope de `{"machine": {...}}` — resposta do trust e do patch.
struct MachineEnvelope: Decodable {
    let machine: Machine
}

// MARK: - Identidades (aba Máquinas)

/// Uma identidade de acesso (usuário + chave + senha opcional) reutilizável
/// entre hosts — separada da máquina desde o redesenho no modelo Termius: a
/// mesma conta de uma VPS não precisa ser recriada a cada host novo dela.
struct Identity: Decodable, Identifiable, Hashable {
    let name: String
    let username: String
    /// Se o hub guarda senha cifrada para ela — decide se `install-key` pode
    /// usar `password: ""` (senha guardada) ou se precisa pedir na hora.
    let hasPassword: Bool
    var id: String { name }
}

/// Resposta de `GET /identities`. `canStorePassword` reflete a config do hub
/// (nem todo hub cifra senha) — controla se o campo de senha aparece ao criar
/// uma identidade nova.
struct IdentityListResponse: Decodable {
    let identities: [Identity]
    let canStorePassword: Bool
}

/// Resposta de `POST /identities`: a identidade criada e a chave PÚBLICA
/// gerada para ela — a privada nasce e fica no hub, nunca sai de lá.
struct IdentityCreated: Decodable {
    let identity: Identity
    let publicKey: String
}

/// Envelope de `{"identity": {...}}` — resposta do PATCH.
struct IdentityEnvelope: Decodable {
    let identity: Identity
}

/// Uma entrada (pasta ou arquivo) no navegador de arquivos da aba Máquinas.
struct FileEntry: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    /// Zero para pasta.
    let size: Int64
    /// Modificação, em segundos desde a epoch.
    let mtime: Int64
    let isDir: Bool
    var id: String { path }

    /// Oculto (começa com ".") — escondido por padrão, como no seletor de pastas.
    var isHidden: Bool { name.hasPrefix(".") }

    var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }

    /// Tamanho legível. Pasta não tem: o hub manda 0 e exibir "Zero KB" mentiria.
    var sizeLabel: String {
        isDir ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Conteúdo navegável de uma pasta: caminho atual, pai (subir), entradas já
/// ordenadas pelo hub (pastas primeiro, cada grupo em ordem alfabética).
struct FileListing: Decodable {
    let path: String
    let parent: String
    let entries: [FileEntry]

    /// Filtra os ocultos sem reordenar — a ordem é a que o hub mandou.
    func visibleEntries(showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }
}

/// Conteúdo de um arquivo lido da máquina. Binário e acima do teto voltam
/// marcados e sem conteúdo — quem decide o que mostrar é o app.
/// Resultado de salvar um arquivo: o tamanho novo, para a tela se atualizar sem
/// reler da máquina.
struct FileWrite: Decodable {
    let path: String
    let size: Int64
}

struct FileContent: Decodable {
    let path: String
    let size: Int64
    let binary: Bool
    let truncated: Bool
    /// Veio só o FIM do arquivo (12/08/2026 — cauda de texto grande). Vale
    /// junto com `truncated`, que continua significando "não veio inteiro".
    ///
    /// **`Bool?`, não `Bool`, e isso não é preciosismo:** o hub só passa a mandar
    /// esta chave depois do deploy, e um `Bool` não-opcional com a chave ausente
    /// **derruba o decode do objeto inteiro** — o visualizador de arquivos
    /// pararia de abrir qualquer coisa contra o hub de produção até ele subir.
    let tail: Bool?
    let content: String

    /// O hub mandou o fim do arquivo em vez do arquivo.
    var ehCauda: Bool { tail == true }

    /// Dá para editar e compartilhar? Só com o arquivo INTEIRO em mãos: salvar
    /// ou compartilhar um pedaço com o nome do todo destruiria/mentiria.
    ///
    /// O `!ehCauda` é redundante com o hub de hoje — lá `tail` só liga dentro do
    /// ramo que já ligou `truncated` — e fica de propósito (revisão, 12/08/2026):
    /// sem ele, a defesa contra o pior bug possível daqui (salvar por cima de um
    /// arquivo do qual só se viu o FIM) moraria inteira no fluxo de controle de
    /// um script python do outro lado da rede. Um `{"truncated":false,
    /// "tail":true}` vindo de outro adaptador, de um bug futuro ou de um mock de
    /// teste já bastaria para liberar Editar. Custa um `&&`.
    var isReadable: Bool { !binary && !truncated && !ehCauda }

    /// Dá para desenhar como texto? A cauda entra aqui e não em `isReadable`:
    /// ler o fim de um log é exatamente o que se quer, escrever por cima não.
    var podeMostrarTexto: Bool { !binary && (!truncated || ehCauda) }

    /// Por que não dá para mostrar como texto (nil quando dá).
    var unreadableReason: String? {
        if binary { return "Arquivo binário — não dá para mostrar como texto." }
        if truncated && !ehCauda { return "Arquivo grande demais (acima de 1 MB) para abrir aqui." }
        return nil
    }
}

// MARK: - Mensagens do WebSocket

/// Mensagens recebidas pelo canal /ws.
/// - `snapshot`: lista completa recebida ao conectar (substitui o estado local).
/// - `sessionUpdated`: uma sessão mudou (upsert na lista).
/// - `outputChunk`: um pedaço de output de uma sessão (usado na tela de detalhe),
///   já com o `kind` (user/assistant/tool/tool_result) para o transcrito estilo chat.
/// - `sessionRemoved`: uma sessão foi apagada no hub (remover da lista).
enum WSMessage: Decodable {
    case snapshot([Session])
    case sessionUpdated(Session)
    case outputChunk(sessionID: String, kind: ChunkKind, text: String)
    case sessionRemoved(sessionID: String)

    private enum CodingKeys: String, CodingKey {
        case type, sessions, session, sessionId, kind, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            let sessions = try container.decode([Session].self, forKey: .sessions)
            self = .snapshot(sessions)
        case "session_updated":
            let session = try container.decode(Session.self, forKey: .session)
            self = .sessionUpdated(session)
        case "output_chunk":
            // `session_id` vira `sessionId` via convertFromSnakeCase no decoder compartilhado.
            // O texto continua na chave `data` no wire do WS (o histórico REST usa `text`).
            let sessionID = try container.decode(String.self, forKey: .sessionId)
            let kind = try container.decode(ChunkKind.self, forKey: .kind)
            let data = try container.decode(String.self, forKey: .data)
            self = .outputChunk(sessionID: sessionID, kind: kind, text: data)
        case "session_removed":
            // `session_id` vira `sessionId` via convertFromSnakeCase no decoder compartilhado.
            let sessionID = try container.decode(String.self, forKey: .sessionId)
            self = .sessionRemoved(sessionID: sessionID)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Tipo de mensagem WS desconhecido: \(type)"
            )
        }
    }
}

// MARK: - Cutuque Board (Kanban dos agentes)

/// Um card do quadro Kanban. Espelha o `board.Task` do hub.
struct BoardTask: Identifiable, Decodable, Equatable {
    let id: String
    var title: String
    var column: String
    var group: String
    var session: String
    var type: String?
    var role: String?
    var encalhada: Bool?
    var archived: Bool?
    var description: String?
    var comments: [BoardComment]?
    var activity: [BoardActivity]?
    var startedAt: Date?
    var reviewedAt: Date?
    var endedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    var isEncalhada: Bool { encalhada ?? false }
    var commentCount: Int { comments?.count ?? 0 }
}

/// Uma observação num card.
struct BoardComment: Decodable, Equatable, Identifiable {
    let author: String
    let text: String
    let createdAt: Date?
    var id: String { "\(author)-\(createdAt?.timeIntervalSince1970 ?? 0)-\(text.hashValue)" }
}

/// Uma entrada do log de atividade (quem fez o quê e quando).
struct BoardActivity: Decodable, Equatable, Identifiable {
    let actor: String
    let action: String
    let at: Date?
    var id: String { "\(actor)-\(at?.timeIntervalSince1970 ?? 0)-\(action.hashValue)" }
}

/// Uma semana do arquivo (concluídos fechados na semana).
struct ArchivedWeek: Identifiable, Decodable, Equatable {
    let label: String            // ex.: "2026-W28"
    let start: String            // "2026-07-06"
    let end: String              // "2026-07-12"
    let tasks: [BoardTask]
    var id: String { label }
}

/// Uma semana candidata a receber o próximo fechamento (`GET /board/close-options`).
struct WeekOption: Decodable, Equatable {
    let label: String            // ex.: "2026-W30"
    let start: String            // "2026-07-20"
    let end: String              // "2026-07-26"
    let count: Int               // quantos JÁ estão arquivados nessa semana
}

/// As opções do fechamento manual. `last` nil = não há escolha a fazer (só a
/// semana do relógio existe), e o fechamento vira o confirmar de sempre.
struct CloseOptions: Decodable, Equatable {
    let current: WeekOption
    let last: WeekOption?
    let pending: Int             // concluídos na fila pra sair do board
}

/// A semana escrita como intervalo em português ("20 – 26 de jul"), do jeito
/// que o arquivo e o popup de fechamento mostram. Datas em "yyyy-MM-dd".
enum WeekRangeFormat {
    static func text(start: String, end: String) -> String {
        let s = parse(start), e = parse(end)
        let day = DateFormatter(); day.locale = Locale(identifier: "pt_BR"); day.dateFormat = "d"
        let mon = DateFormatter(); mon.locale = Locale(identifier: "pt_BR"); mon.dateFormat = "MMM"
        let sMon = mon.string(from: s).replacingOccurrences(of: ".", with: "")
        let eMon = mon.string(from: e).replacingOccurrences(of: ".", with: "")
        let cal = Calendar.current
        if cal.component(.month, from: s) == cal.component(.month, from: e) {
            return "\(day.string(from: s)) – \(day.string(from: e)) de \(eMon)"
        }
        return "\(day.string(from: s)) de \(sMon) – \(day.string(from: e)) de \(eMon)"
    }

    static func parse(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
}

/// O texto do popup de fechamento. Fica fora da view pra poder ser testado —
/// e é o mesmo texto do dashboard, pra iPhone, iPad e web falarem igual.
enum CloseWeekPrompt {
    static func title(_ opts: CloseOptions?) -> String {
        opts?.last == nil ? "Fechar a semana agora?" : "Onde arquivar?"
    }

    static func message(_ opts: CloseOptions?) -> String {
        // Fila vazia: fechar ainda vale (é o que marca os encalhados), mas dizer
        // "0 concluídos vão sair do board" só confunde.
        if let o = opts, o.pending == 0 {
            return "Nada concluído na fila. Fechar agora só marca como encalhados os to-dos que nunca começaram."
        }
        let alvo = opts.map { "\($0.pending) concluído\($0.pending == 1 ? "" : "s")" } ?? "Os cards concluídos"
        guard opts?.last != nil else {
            return "\(alvo) serão arquivados e saem do board; to-dos antigos não iniciados viram encalhados. Normalmente acontece sozinho no domingo 23:59."
        }
        return "\(alvo) vão sair do board. Se este trabalho é da virada de madrugada, junte na semana que acabou em vez de abrir uma nova."
    }

    static func juntarLabel(_ last: WeekOption) -> String {
        "Juntar em \(WeekRangeFormat.text(start: last.start, end: last.end)) (\(last.count))"
    }

    static func novaLabel(_ current: WeekOption) -> String {
        "Criar semana nova (\(WeekRangeFormat.text(start: current.start, end: current.end)))"
    }
}

/// Colunas do quadro, na ordem do fluxo (igual ao hub).
enum BoardColumn: String, CaseIterable, Identifiable {
    case aFazer = "a_fazer"
    case emProgresso = "em_progresso"
    case feito
    case emRevisao = "em_revisao"
    case concluido
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aFazer:      return "A fazer"
        case .emProgresso: return "Em progresso"
        case .feito:       return "Feito"
        case .emRevisao:   return "Em revisão"
        case .concluido:   return "Concluído"
        }
    }
}

/// Cor por tipo de IA (igual ao dashboard web): Claude azul, Codex verde,
/// OpenCode roxo; cinza para tipo desconhecido.
enum AgentTypeColor {
    static func color(for type: String?) -> Color {
        switch (type ?? "").lowercased() {
        case "claude":   return Color(red: 0.18, green: 0.50, blue: 0.98) // azul
        case "codex":    return Color(red: 0.13, green: 0.77, blue: 0.37) // verde
        case "opencode": return Color(red: 0.66, green: 0.33, blue: 0.97) // roxo
        default:         return .secondary
        }
    }
}

/// Cor da tag de ambiente (grupo): paleta sortida, determinística por nome (mesma
/// do dashboard web). Tons quentes/rosados/teal/marrom — distintos de azul/verde/roxo.
enum GroupColor {
    static let palette: [Color] = [
        "#f5a623", "#f97316", "#ea580c", "#ec4899", "#db2777", "#f43f5e", "#e11d48",
        "#be123c", "#eab308", "#ca8a04", "#14b8a6", "#0d9488", "#fb7185", "#b45309",
    ].map { Color(hex: $0) }

    static func color(for name: String) -> Color {
        guard !name.isEmpty else { return .secondary }
        var h: UInt32 = 0
        for u in name.unicodeScalars { h = h &* 31 &+ u.value }
        return palette[Int(h % UInt32(palette.count))]
    }
}

extension Color {
    /// Cria uma Color a partir de "#RRGGBB".
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - Decoder compartilhado

extension JSONDecoder {
    /// Decoder usado tanto pela API REST quanto pelo WS.
    /// - snake_case → camelCase (created_at → createdAt).
    /// - datas RFC3339/ISO8601, com ou sem fração de segundos.
    static let cutuque: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            if let date = JSONDecoder.iso8601WithFraction.date(from: raw)
                ?? JSONDecoder.iso8601Plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try d.singleValueContainer(),
                debugDescription: "Data RFC3339 inválida: \(raw)"
            )
        }
        return decoder
    }()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
