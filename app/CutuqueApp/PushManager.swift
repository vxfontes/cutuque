import Foundation
import UIKit
import UserNotifications

// MARK: - Identificadores de categorias e ações

/// Constantes do contrato de push com o hub. As categorias vêm no `aps.category`
/// do payload; as ações são as escolhidas pelo usuário na notificação.
enum PushCategory {
    static let needsYou = "NEEDS_YOU"
    static let done = "DONE"
    static let error = "ERROR"
}

enum PushAction {
    static let approve = "APPROVE_ACTION"
    static let deny = "DENY_ACTION"
    static let open = "OPEN_ACTION"
    static let reply = "REPLY_ACTION" // resposta em texto direto da notificação
}

// MARK: - Router de deep-link

/// Roteador observável para deep-link vindo de uma notificação.
/// A `SessionListView` observa `pendingSessionID` e navega até o detalhe da sessão.
/// Não é `@MainActor` para poder ser lido no init do `App` sem violar isolamento;
/// as mutações vêm sempre da main thread (handler de notificação em `@MainActor`).
final class Router: ObservableObject {
    static let shared = Router()

    /// ID da sessão a abrir; a lista consome e zera após navegar.
    @Published var pendingSessionID: String?

    private init() {}

    /// Pede para abrir o detalhe de uma sessão (tap na notificação / ação "Abrir").
    func openSession(_ sessionID: String) {
        pendingSessionID = sessionID
    }
}

// MARK: - PushManager

/// Gerencia autorização, categorias e envio do device token ao hub.
@MainActor
final class PushManager {
    static let shared = PushManager()

    let router = Router.shared
    private let api = APIClient()

    private init() {}

    /// Pede autorização de notificações (alerta+som+badge). Se concedida,
    /// registra para remote notifications (dispara o callback do device token).
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            // .timeSensitive: sem ela (e sem a entitlement correspondente) a Apple
        // rebaixa o interruption-level do needs_you e o cutucão não fura
        // Focus/DND (review F4, bloqueante #2).
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            guard granted else {
                print("[Push] autorização negada pelo usuário")
                return
            }
            // registerForRemoteNotifications precisa rodar na main thread.
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            print("[Push] erro ao pedir autorização: \(error.localizedDescription)")
        }
    }

    /// Re-registra o device no hub (se já autorizado) — chamado quando o app
    /// volta ao foreground. Recupera o registro depois de um restart do hub (os
    /// devices ficam em memória e somem no reboot do container). registerFor…
    /// re-dispara o callback do token, que faz o upsert no hub.
    func refreshRegistration() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Define as categorias com ações conforme o contrato do hub.
    /// - NEEDS_YOU: Aprovar / Negar (destrutiva) / Abrir (foreground)
    /// - DONE e ERROR: Abrir (foreground)
    func registerCategories() {
        // Responder em texto direto da notificação (múltipla escolha do tmux ou
        // resposta livre): o hub roteia (send-keys no tmux / stdin no app-launched).
        let reply = UNTextInputNotificationAction(
            identifier: PushAction.reply, title: "Responder", options: [],
            textInputButtonTitle: "Enviar", textInputPlaceholder: "Responder ao agente…")
        let approve = UNNotificationAction(
            identifier: PushAction.approve, title: "Aprovar", options: [])
        let deny = UNNotificationAction(
            identifier: PushAction.deny, title: "Negar", options: [.destructive])
        let open = UNNotificationAction(
            identifier: PushAction.open, title: "Abrir", options: [.foreground])

        let needsYou = UNNotificationCategory(
            identifier: PushCategory.needsYou,
            actions: [reply, approve, deny, open],
            intentIdentifiers: [], options: [])
        let done = UNNotificationCategory(
            identifier: PushCategory.done,
            actions: [open], intentIdentifiers: [], options: [])
        let error = UNNotificationCategory(
            identifier: PushCategory.error,
            actions: [open], intentIdentifiers: [], options: [])

        UNUserNotificationCenter.current().setNotificationCategories([needsYou, done, error])
    }

    /// Converte o device token bruto em hex e envia ao hub. Falha silenciosa
    /// com 1 retry (o registro é best-effort; sem push o app ainda funciona).
    func sendDeviceToken(_ tokenData: Data) async {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        for attempt in 1...2 {
            do {
                try await api.registerDevice(token: hex)
                print("[Push] device token registrado no hub")
                return
            } catch {
                print("[Push] falha ao registrar token (tentativa \(attempt)): \(error.localizedDescription)")
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // espera 2s antes do retry
                }
            }
        }
    }

    /// Trata a ação escolhida pelo usuário na notificação.
    /// - Aprovar/Negar chamam o hub direto (rodam mesmo em background).
    /// - Abrir / tap padrão fazem deep-link para o detalhe da sessão.
    func handle(_ response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo["session_id"] as? String

        switch response.actionIdentifier {
        case PushAction.reply:
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            if let id = sessionID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await reply(sessionID: id, text: text)
            }
        case PushAction.approve:
            if let id = sessionID { await decide(sessionID: id, approve: true) }
            else { print("[Push] ação Aprovar sem session_id no userInfo") }
        case PushAction.deny:
            if let id = sessionID { await decide(sessionID: id, approve: false) }
            else { print("[Push] ação Negar sem session_id no userInfo") }
        case PushAction.open, UNNotificationDefaultActionIdentifier:
            if let id = sessionID { router.openSession(id) }
        default:
            break
        }
    }

    /// Envia uma resposta em texto à sessão (do push), com 1 retry. O hub roteia
    /// para o tmux (send-keys) ou stdin conforme a sessão.
    private func reply(sessionID: String, text: String) async {
        for attempt in 1...2 {
            do {
                try await api.reply(sessionID: sessionID, text: text)
                return
            } catch {
                print("[Push] falha ao responder (tentativa \(attempt)): \(error.localizedDescription)")
                if attempt == 1 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
    }

    /// Aprova/nega com 1 retry (mesmo padrão best-effort de sendDeviceToken).
    /// A pior falha aqui é a silenciosa: a usuária acreditar que aprovou e o
    /// agente seguir preso esperando (review F4, bloqueante #1). Em falha
    /// definitiva, agenda uma notificação local orientando a abrir o app.
    private func decide(sessionID: String, approve: Bool) async {
        for attempt in 1...2 {
            do {
                if approve {
                    try await api.approve(sessionID: sessionID)
                } else {
                    try await api.deny(sessionID: sessionID)
                }
                return
            } catch CutuqueError.staleState {
                // Estado já mudou (ex.: sessão concluiu antes do tap) — nada a refazer.
                print("[Push] decisão obsoleta para \(sessionID) — estado já mudou")
                return
            } catch {
                print("[Push] falha ao \(approve ? "aprovar" : "negar") (tentativa \(attempt)): \(error.localizedDescription)")
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s antes do retry
                }
            }
        }
        await notifyActionFailure(sessionID: sessionID, approve: approve)
    }

    /// Notificação local de falha definitiva da ação — o feedback que evita a
    /// falsa sensação de "aprovado".
    private func notifyActionFailure(sessionID: String, approve: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = "Falha ao \(approve ? "aprovar" : "negar")"
        content.body = "Não consegui falar com o hub — abra o app para decidir."
        content.sound = .default
        content.categoryIdentifier = PushCategory.error
        content.userInfo = ["session_id": sessionID]
        let request = UNNotificationRequest(
            identifier: "action-failure-\(sessionID)",
            content: content,
            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - AppDelegate

/// Delegate de app + de notificações. Ligado no `CutuqueApp` via
/// `@UIApplicationDelegateAdaptor`. Encaminha o trabalho ao `PushManager`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushManager.shared.registerCategories()
        return true
    }

    // MARK: Device token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushManager.shared.sendDeviceToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // No simulador sem APNs real isso pode falhar — apenas registramos.
        print("[Push] falha ao registrar para remote notifications: \(error.localizedDescription)")
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Ação tocada na notificação. Segura o app vivo com uma background task
    /// enquanto a chamada de rede (aprovar/negar) completa.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let app = UIApplication.shared
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        var finished = false

        // Encerra exatamente uma vez: devolve o controle ao sistema e libera a
        // background task. Chamado tanto no caminho normal quanto na expiração
        // (delegate e expirationHandler rodam ambos na main thread → sem corrida).
        func finishOnce() {
            guard !finished else { return }
            finished = true
            completionHandler()
            if bgTask != .invalid {
                app.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        // Se o iOS expirar o tempo de background antes da rede terminar, ainda
        // assim encerramos (senão a task vaza e o completionHandler nunca é chamado).
        bgTask = app.beginBackgroundTask(withName: "cutuque.push.action") {
            finishOnce()
        }
        Task { @MainActor in
            await PushManager.shared.handle(response)
            finishOnce()
        }
    }

    /// App em foreground: em foreground já temos haptics locais via WebSocket,
    /// mas ainda mostramos banner + som (simples e aceitável nesta fase).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
