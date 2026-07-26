import Foundation

/// Segura a rajada de `tmuxResize` que o iPad provoca. A largura da view muda
/// na rotação, no botão de expandir e — pior — a cada frame do arraste do
/// divisor do Split View: sem isto, dezenas de POSTs seguidos pro hub.
///
/// Duas garantias: só o último tamanho da janela vira chamada, e um tamanho
/// igual ao último efetivamente enviado não vira chamada nenhuma.
@MainActor
final class ResizeDebouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var lastSent: (cols: Int, rows: Int)?

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    func schedule(cols: Int, rows: Int, send: @escaping @MainActor (Int, Int) -> Void) {
        if let last = lastSent, last.cols == cols, last.rows == rows { return }
        pending?.cancel()
        // `[weak self]`: sem isto, `self` ficaria retido por forte dentro do
        // Task, que por sua vez é retido por `self.pending` — um ciclo
        // clássico (self → pending → closure → self). O dono (a view do
        // terminal) chama `cancel()` no teardown e isso já quebra o ciclo,
        // mas capturar fraco é a segunda trava: se algum caminho futuro
        // esquecer de chamar `cancel()`, o objeto ainda assim é liberado
        // quando o último dono externo soltar, e o resize atrasado nunca
        // dispara — em vez de vazar até o delay todo passar.
        pending = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.lastSent = (cols, rows)
            send(cols, rows)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Ritmo do polling do espelho. Uma captura de 220×60 é ~13 KB contra ~4 KB da
/// tela do iPhone: com a tela parada, 1,5 s é gasto de bateria e rede à toa.
struct PollPacer {
    static let fast: Duration = .milliseconds(1500)
    static let slow: Duration = .seconds(3)
    static let idleThreshold: TimeInterval = 30

    private(set) var quietFor: TimeInterval = 0

    mutating func record(changed: Bool, elapsed: TimeInterval) {
        quietFor = changed ? 0 : quietFor + elapsed
    }

    var interval: Duration { quietFor >= Self.idleThreshold ? Self.slow : Self.fast }
}

extension Duration {
    /// A duração em segundos, para contas de tempo ocioso.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
