import Foundation

/// Conexão com o terminal livre de uma máquina: `GET /machines/{n}/pty` por
/// WebSocket, bytes crus nos dois sentidos.
///
/// O protocolo distingue conteúdo de metadado pelo TIPO do frame, não por
/// prefixo nos bytes: binário é o terminal (nos dois sentidos), texto é
/// controle. Isso importa porque o terminal transporta bytes arbitrários —
/// qualquer marcador dentro do fluxo seria escapável por acidente.
///
///     app → hub, binário: o que foi digitado
///     app → hub, texto:   {"type":"resize","cols","rows"}
///     hub → app, binário: a saída do terminal
///     hub → app, texto:   {"type":"exit","code"} | {"type":"error","message"}
///
/// Ao contrário do `liveUpdates()`, **não reconecta sozinho**: um shell é
/// estado (diretório, variáveis, o que estava editando) e reconectar daria um
/// shell novo com cara do antigo. Caiu, a usuária decide se reconecta.
@MainActor
final class PTYSession: ObservableObject {
    /// Em que pé está a conexão. `encerrado` e `caiu` são coisas diferentes de
    /// propósito: sair com `exit` é normal, a rede cair não é.
    enum Estado: Equatable {
        case parado
        case conectando
        case ligado
        /// O shell do outro lado terminou, com este código.
        case encerrado(Int)
        /// A conexão morreu, ou o hub recusou abrir o terminal.
        case caiu(String)
    }

    @Published private(set) var estado: Estado = .parado

    /// Chamado a cada pedaço de saída do terminal. Quem liga é a
    /// `PTYTerminalView`, que repassa para o emulador.
    var aoReceber: (ArraySlice<UInt8>) -> Void = { _ in }

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    /// Tamanho que o emulador mediu por último. Guardado mesmo sem conexão,
    /// para o `abre()` já entrar com a tela certa em vez de abrir 80x24 e
    /// corrigir depois — o shell do outro lado já teria desenhado o prompt
    /// torto.
    private var tamanhoMedido: (cols: Int, rows: Int)?
    /// Último tamanho que o hub realmente recebeu. Separado do medido porque o
    /// SwiftTerm chama `sizeChanged` também quando só o layout se mexeu, e cada
    /// resize repetido vira um SIGWINCH que faz a TUI redesenhar a tela inteira.
    private var tamanhoEnviado: (cols: Int, rows: Int)?

    private let machine: String
    /// Tamanho do handshake quando ninguém mediu nada ainda. É o mesmo padrão
    /// do hub — combinar os dois evita um resize inútil na abertura.
    static let tamanhoPadrao = (cols: 80, rows: 24)

    init(machine: String) {
        self.machine = machine
    }

    deinit {
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Ciclo de vida

    /// Abre a conexão, se ainda não houver uma. Chamar de novo com o terminal
    /// vivo não faz nada — é o que deixa a view reentrar à vontade (voltar de
    /// uma subpasta, trocar de painel) sem derrubar o shell.
    ///
    /// Não recebe tamanho: quem mede é o emulador, e ele já contou pelo
    /// `resize()`. Reabrir depois de um `encerrado`/`caiu` é permitido e abre um
    /// shell NOVO — recuperar o antigo não existe.
    func abre() {
        guard estado == .parado || estado.acabou else { return }
        let (cols, rows) = tamanhoMedido ?? Self.tamanhoPadrao
        estado = .conectando

        let ws = URLSession.shared.webSocketTask(with: Self.ptyURL(machine: machine, cols: cols, rows: rows))
        task = ws
        ws.resume()
        estado = .ligado
        // O tamanho já foi no handshake: só um resize DIFERENTE precisa ir.
        tamanhoEnviado = (cols, rows)

        loop = Task { [weak self] in await self?.recebe(ws) }
    }

    /// Fecha de vez. O hub mata o `ssh` junto — sessão efêmera é o modelo (não
    /// há tmux no meio para sobreviver).
    func disconnect() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        tamanhoEnviado = nil
        if !estado.acabou { estado = .parado }
    }

    /// Para de consumir o socket sem fechá-lo — é o que o painel inativo faz.
    ///
    /// A saída não se perde: fica na fila do `URLSessionWebSocketTask` e chega
    /// toda de uma vez no `resume()`. O emulador processa o acumulado e mostra
    /// a tela final, que é o que interessa depois de voltar.
    func suspend() {
        loop?.cancel()
        loop = nil
    }

    /// Volta a consumir o socket. Sem conexão viva, não faz nada — quem
    /// reconecta é a view, que sabe o tamanho da tela.
    func resume() {
        guard let ws = task, estado == .ligado, loop == nil else { return }
        loop = Task { [weak self] in await self?.recebe(ws) }
    }

    // MARK: - Envio

    /// Manda ao terminal o que foi digitado.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard let task, estado == .ligado, !bytes.isEmpty else { return }
        task.send(.data(Data(bytes))) { _ in
            // Falha de envio aparece como leitura morrendo no loop, que é onde
            // o estado muda — reportar aqui daria a mesma queda duas vezes.
        }
    }

    /// Registra o tamanho medido pelo emulador e, se houver conexão, avisa o
    /// outro lado. Sem conexão fica guardado — é o que o `abre()` usa no
    /// handshake.
    ///
    /// Repetição é descartada: cada resize vira um SIGWINCH, e aplicação TUI
    /// redesenha a tela inteira a cada um.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        tamanhoMedido = (cols, rows)

        guard let task, estado == .ligado else { return }
        if let enviado = tamanhoEnviado, enviado == (cols, rows) { return }
        tamanhoEnviado = (cols, rows)
        task.send(.string(Self.resizeJSON(cols: cols, rows: rows))) { _ in }
    }

    /// Mensagem de controle do resize. Só inteiros entram, então concatenar é
    /// seguro e evita um encoder por tecla de rotação.
    ///
    /// `nonisolated` porque é função pura: não toca em nada da conexão, e
    /// exigir a main actor só para montar uma string obrigaria todo teste a ser
    /// `@MainActor` sem ganhar segurança nenhuma.
    nonisolated static func resizeJSON(cols: Int, rows: Int) -> String {
        #"{"type":"resize","cols":\#(cols),"rows":\#(rows)}"#
    }

    // MARK: - Recepção

    private func recebe(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await ws.receive()
                guard !Task.isCancelled else { return }
                switch msg {
                case .data(let bytes):
                    aoReceber(ArraySlice(bytes))
                case .string(let texto):
                    if aplica(evento: texto) { return } // "exit"/"error" acabam aqui
                @unknown default:
                    break
                }
            } catch {
                // Cancelamento é o `suspend()`, não uma queda: o socket segue
                // vivo e o `resume()` volta a ler.
                guard !Task.isCancelled else { return }
                if !estado.acabou {
                    estado = .caiu(error.localizedDescription)
                }
                return
            }
        }
    }

    /// Aplica um evento de texto do hub. Devolve `true` quando ele encerra a
    /// sessão (não há o que ler depois).
    private func aplica(evento texto: String) -> Bool {
        guard let ev = PTYEvent(json: texto) else { return false }
        switch ev {
        case .exit(let code):
            estado = .encerrado(code)
        case .erro(let msg):
            estado = .caiu(msg)
        }
        return true
    }

    /// Monta `ws://host/machines/{n}/pty?token=…&cols=…&rows=…`.
    ///
    /// O tamanho vai já no handshake porque o app mede a tela ANTES de
    /// conectar: sem isso o shell abriria 80x24, desenharia o prompt torto e só
    /// então receberia o resize.
    nonisolated static func ptyURL(machine: String, cols: Int, rows: Int,
                                   base: URL = HubSettings.baseURL,
                                   token: String = HubSettings.token) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        // `path` (não `percentEncodedPath`): assim o próprio URLComponents
        // escapa o nome, e uma máquina com caractere especial não escapa do
        // segmento de caminho.
        comps.path = "/machines/\(machine)/pty"
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "cols", value: String(cols)),
            URLQueryItem(name: "rows", value: String(rows)),
        ]
        return comps.url!
    }
}

/// Evento de texto vindo do hub. Tipo desconhecido vira `nil` — um hub mais
/// novo falando com um app mais velho não pode derrubar o terminal.
enum PTYEvent: Equatable {
    case exit(Int)
    case erro(String)

    init?(json: String) {
        struct Corpo: Decodable {
            let type: String
            let code: Int?
            let message: String?
        }
        guard let data = json.data(using: .utf8),
              let c = try? JSONDecoder().decode(Corpo.self, from: data)
        else { return nil }
        switch c.type {
        case "exit":  self = .exit(c.code ?? 0)
        case "error": self = .erro(c.message ?? "o hub não conseguiu abrir o terminal")
        default:      return nil
        }
    }
}

extension PTYSession.Estado {
    /// Verdadeiro quando a sessão terminou — de qualquer jeito. É o que
    /// autoriza um `connect()` novo.
    var acabou: Bool {
        switch self {
        case .encerrado, .caiu: return true
        case .parado, .conectando, .ligado: return false
        }
    }

    /// Frase para a usuária, ou `nil` quando não há nada a dizer (rodando).
    var recado: String? {
        switch self {
        case .parado, .conectando, .ligado:
            return nil
        case .encerrado(let code):
            return code == 0 ? "Terminal encerrado." : "Terminal encerrado (código \(code))."
        case .caiu(let msg):
            return msg
        }
    }
}
