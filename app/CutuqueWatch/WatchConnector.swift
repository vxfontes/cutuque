import Foundation
import WatchConnectivity
import WatchKit

/// Cliente FINO do Watch: não fala com o hub direto (o hub só existe na
/// Tailscale, que o relógio não alcança). Em vez disso, manda pedidos ao iPhone
/// via WatchConnectivity; o iPhone faz o HTTP e responde. Precisa do iPhone por
/// perto/alcançável.
///
/// Os tipos do wire e a máquina de estados da tela ficam em `SharedWatch/` —
/// código puro que a suíte de testes (alvo iOS) consegue ver. Aqui fica só o
/// que depende de WatchConnectivity e do relógio.
@MainActor
final class WatchConnector: NSObject, ObservableObject {
    @Published private(set) var sessions: [WatchSession] = []
    @Published private(set) var overview = WatchOverview()
    @Published private(set) var phase: WatchLoadPhase = .inicial
    /// Há um `needsYou` em voo. Separado de `phase` de propósito: um refresh de
    /// fundo não pode apagar o que já está na tela (ver `WatchLoadPhase`).
    @Published private(set) var refreshing = false
    @Published private(set) var reachable = false
    /// Quando a última resposta VÁLIDA chegou — alimenta o "atualizado há Xs".
    @Published private(set) var lastUpdated: Date?
    /// Ação (aprovar/negar/responder) em voo, pelo id da sessão. Enquanto está
    /// aqui, a tela de ação mostra "enviando…" em vez de sumir na hora.
    @Published private(set) var sending: String?
    /// Última ação que falhou, pra tela de ação poder dizer isso em vez de
    /// fechar como se tivesse dado certo.
    @Published var actionError: String?

    var loading: Bool { refreshing }

    /// A tela a desenhar agora. Decidida em `SharedWatch/WatchWire.swift`.
    var screen: WatchScreen {
        WatchScreenState.screen(phase: phase, reachable: reachable, sessions: sessions, overview: overview)
    }

    /// Ids de needs_you já vistos: uma sessão NOVA na lista dispara o haptic de
    /// "precisa de você" no pulso. `loadedOnce` evita vibrar na 1ª carga.
    private var knownIDs: Set<String> = []
    private var loadedOnce = false

    /// Auto-refresh enquanto o app está na frente. Sem isso, a lista congelava
    /// no momento em que você abriu o app: uma sessão que travou 10 s depois só
    /// aparecia se você lembrasse de tocar no botão de recarregar.
    private var ticker: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(10)

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        refresh()
    }

    /// Chamado quando a cena entra/sai de foreground. O relógio desliga a tela
    /// sozinho depois de segundos — deixar um timer rodando de fundo só gasta
    /// bateria e mantém o iPhone acordado à toa.
    func setActive(_ active: Bool) {
        ticker?.cancel()
        guard active else { ticker = nil; return }
        refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.refreshIfIdle()
            }
        }
    }

    /// Refresh do timer: não empilha em cima de um pedido já em voo.
    private func refreshIfIdle() {
        guard !refreshing, sending == nil else { return }
        refresh()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        send([WatchWireKey.action: "needsYou"]) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            switch result {
            case .falha(let motivo):
                self.phase = .falhou(motivo)
            case .ok(let raw):
                // Resposta sem a chave `sessions` é resposta de ERRO do iPhone
                // (ou lixo) — não é "não há nada precisando de você". Tratar as
                // duas igual era o bug que fazia o pulso dizer "Tudo em dia"
                // com o hub cheio de pedidos parados.
                guard let reply = WatchNeedsYouReply(wire: raw) else {
                    self.phase = .falhou(raw[WatchWireKey.error] as? String ?? "resposta ilegível do iPhone")
                    return
                }
                self.apply(reply)
            }
        }
    }

    private func apply(_ reply: WatchNeedsYouReply) {
        // Haptic de "precisa de você" quando uma sessão NOVA aparece (não na
        // 1ª carga). É o cutucão no pulso — distinto do toque de confirmação.
        let ids = Set(reply.sessions.map(\.id))
        if loadedOnce && !ids.subtracting(knownIDs).isEmpty {
            WKInterfaceDevice.current().play(.notification)
        }
        knownIDs = ids
        loadedOnce = true
        sessions = reply.sessions
        overview = reply.overview
        lastUpdated = Date()
        phase = .carregado
    }

    // MARK: - Ações

    func approve(_ id: String) { act(id, [WatchWireKey.action: "approve", WatchWireKey.id: id], haptic: .success) }
    func deny(_ id: String) { act(id, [WatchWireKey.action: "deny", WatchWireKey.id: id], haptic: .directionDown) }

    func reply(_ id: String, _ text: String) {
        act(id, [WatchWireKey.action: "reply", WatchWireKey.id: id, WatchWireKey.text: text], haptic: .success)
    }

    /// Responde a uma pergunta de seleção. `answers` já vem pronto como
    /// `[{"question": ..., "selected": [...]}]` (o iPhone só repassa ao hub).
    func answer(_ id: String, _ answers: [[String: Any]]) {
        act(id, [WatchWireKey.action: "answer", WatchWireKey.id: id, WatchWireKey.answers: answers], haptic: .success)
    }

    /// Ação que muda estado. Fica em `sending` até o iPhone confirmar: a tela
    /// só fecha depois do `ok`. Antes fechava na hora, então uma aprovação que
    /// não chegou ao hub era indistinguível de uma que chegou.
    private func act(_ id: String, _ msg: [String: Any], haptic: WKHapticType) {
        guard sending == nil else { return }
        sending = id
        actionError = nil
        send(msg) { [weak self] result in
            guard let self else { return }
            self.sending = nil
            switch result {
            case .ok(let raw) where raw[WatchWireKey.ok] as? Bool == true:
                WKInterfaceDevice.current().play(haptic)
                self.refresh()
            case .ok:
                self.actionError = "o hub recusou — tente pelo iPhone"
                WKInterfaceDevice.current().play(.failure)
            case .falha(let motivo):
                self.actionError = motivo
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    // MARK: - Transporte

    /// Desfecho de um `sendMessage`. `Result` não serve: o caso de falha aqui
    /// é uma frase pronta pro mostrador, não um `Error`.
    enum SendOutcome {
        case ok([String: Any])
        case falha(String)
    }

    private func send(_ msg: [String: Any], reply: @escaping (SendOutcome) -> Void) {
        let s = WCSession.default
        guard s.activationState == .activated else {
            reachable = false
            reply(.falha("conexão com o iPhone não iniciou"))
            return
        }
        guard s.isReachable else {
            reachable = false
            reply(.falha("iPhone fora de alcance"))
            return
        }
        s.sendMessage(msg, replyHandler: { r in
            Task { @MainActor in
                self.reachable = true
                reply(.ok(r))
            }
        }, errorHandler: { error in
            Task { @MainActor in
                self.reachable = WCSession.default.isReachable
                reply(.falha(Self.motivo(error)))
            }
        })
    }

    /// Texto curto o bastante pro mostrador. As mensagens do WatchConnectivity
    /// são longas e em inglês ("WCErrorCodeDeliveryFailed…").
    private static func motivo(_ error: Error) -> String {
        guard let code = (error as? WCError)?.code else { return "não consegui falar com o iPhone" }
        switch code {
        case .notReachable, .deviceNotPaired, .companionAppNotInstalled:
            return "iPhone fora de alcance"
        case .messageReplyTimedOut, .deliveryFailed, .messageReplyFailed:
            return "o iPhone não respondeu"
        case .sessionNotActivated, .sessionMissingDelegate, .sessionInactive:
            return "conexão com o iPhone não iniciou"
        default:
            return "não consegui falar com o iPhone"
        }
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.reachable = session.isReachable
            if state == .activated { self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.reachable = session.isReachable
            // O iPhone acabou de voltar ao alcance: puxe agora, sem esperar o
            // próximo tique nem exigir um toque no botão.
            if session.isReachable { self.refresh() }
        }
    }
}
