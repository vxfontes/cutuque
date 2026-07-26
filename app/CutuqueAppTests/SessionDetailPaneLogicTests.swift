import XCTest
@testable import CutuqueApp

final class SessionDetailPaneLogicTests: XCTestCase {

    // MARK: - terminalTarget

    /// `Session` só tem `init(from:)` — decodifica um JSON mínimo pelo mesmo
    /// `JSONDecoder.cutuque` usado pelo `APIClient`, com `pane` opcional pra
    /// simular sessão com/sem terminal tmux.
    private func makeSession(id: String = "s1", machine: String = "mac1",
                              title: String = "sessão original", pane: String? = nil) -> Session {
        // Escapa a tabulação do alvo tmux ("<socket>\t<pane>") pra virar `\t`
        // no TEXTO do JSON — um caractere de controle cru dentro de uma string
        // JSON é inválido e faz o decode desse campo falhar silenciosamente
        // (o `pane` do `Session` é `try?`), quebrando o teste sem ligação
        // nenhuma com o código de produção.
        let escapedPane = pane?.replacingOccurrences(of: "\t", with: "\\t")
        let paneField = escapedPane.map { "\"pane\": \"\($0)\"," } ?? ""
        let json = """
        {
            "id": "\(id)", "machine": "\(machine)", "agent": "claude-code",
            "title": "\(title)", "state": "running",
            "createdAt": "2026-07-26T12:00:00Z", "updatedAt": "2026-07-26T12:00:00Z",
            \(paneField)
        }
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    /// Entrada `.live` sempre tem alvo tmux — vem direto do terminal ao vivo,
    /// nunca do registry, então nunca depende de `pane`.
    func testLiveSempreTemAlvoTmux() {
        let entry = LiveEntry(machine: "mac1", session: DiscoveredSession(
            id: "abc", cwd: "/tmp", title: "sessão viva"
        ))
        let result = SessionDetailPaneLogic.terminalTarget(for: .live(entry)) { $0.title }

        XCTAssertEqual(result?.machine, "mac1")
        XCTAssertEqual(result?.target, "abc")
        XCTAssertEqual(result?.title, "sessão viva")
    }

    /// Sessão do registry SEM `pane` (não roda dentro do tmux) não tem alvo —
    /// é o caso comum de uma sessão lançada pelo app fora do tmux.
    func testSessionSemPaneNaoTemAlvoTmux() {
        let session = makeSession(pane: nil)
        let result = SessionDetailPaneLogic.terminalTarget(for: .session(session)) { $0.title }

        XCTAssertNil(result)
    }

    /// Sessão do registry COM `pane` tem alvo tmux, e o título vem do closure
    /// `displayTitle` (o apelido local do `SessionNamesStore`, não o
    /// `session.title` original) — é o motivo de parametrizar por closure.
    func testSessionComPaneUsaDisplayTitleDoClosure() {
        let session = makeSession(machine: "mac2", title: "sessão original", pane: "sock1\tpane3")
        let result = SessionDetailPaneLogic.terminalTarget(for: .session(session)) { _ in "apelido" }

        XCTAssertEqual(result?.machine, "mac2")
        XCTAssertEqual(result?.target, "sock1\tpane3")
        XCTAssertEqual(result?.title, "apelido")
    }

    // MARK: - correctedPaneMode

    /// Seleção com os dois painéis disponíveis nunca força nada — o usuário
    /// decide livremente entre chat e terminal.
    func testComOsDoisPaineisNaoForcaNada() {
        XCTAssertNil(SessionDetailPaneLogic.correctedPaneMode(hasChat: true, hasTerminal: true, current: .chat))
        XCTAssertNil(SessionDetailPaneLogic.correctedPaneMode(hasChat: true, hasTerminal: true, current: .terminal))
    }

    /// Sem chat (ex.: entrada `.live` sem sessão do registry correspondente,
    /// hipoteticamente) só pode mostrar terminal — se já está em terminal,
    /// nada muda; se está em chat, força a correção.
    func testSemChatForcaTerminal() {
        XCTAssertEqual(SessionDetailPaneLogic.correctedPaneMode(hasChat: false, hasTerminal: true, current: .chat), .terminal)
        XCTAssertNil(SessionDetailPaneLogic.correctedPaneMode(hasChat: false, hasTerminal: true, current: .terminal))
    }

    /// Sem terminal (sessão fora do tmux) só pode mostrar chat — mesma lógica
    /// espelhada.
    func testSemTerminalForcaChat() {
        XCTAssertEqual(SessionDetailPaneLogic.correctedPaneMode(hasChat: true, hasTerminal: false, current: .terminal), .chat)
        XCTAssertNil(SessionDetailPaneLogic.correctedPaneMode(hasChat: true, hasTerminal: false, current: .chat))
    }

    // MARK: - paneTitle

    /// Com Chat em foco e os dois títulos disponíveis, mostra o do chat —
    /// nunca o do terminal, mesmo que ele exista.
    func testComChatEmFocoMostraTituloDoChat() {
        let title = SessionDetailPaneLogic.paneTitle(
            showsChat: true, chatTitle: "sessão", terminalTitle: "sessão (tmux)"
        )
        XCTAssertEqual(title, "sessão")
    }

    /// Com Terminal em foco, o espelho — nunca o do chat.
    func testComTerminalEmFocoMostraTituloDoTerminal() {
        let title = SessionDetailPaneLogic.paneTitle(
            showsChat: false, chatTitle: "sessão", terminalTitle: "sessão (tmux)"
        )
        XCTAssertEqual(title, "sessão (tmux)")
    }

    /// Seleção sem chat (só `.live` sem sessão do registry, hipoteticamente):
    /// `correctedPaneMode` já forçaria `showsChat == false` neste caso, mas
    /// mesmo que `showsChat` chegasse `true` por algum motivo, o título cai
    /// pro terminal em vez de virar `""` — nunca fica em branco à toa.
    func testSemChatCaiProTituloDoTerminalMesmoComShowsChatTrue() {
        let title = SessionDetailPaneLogic.paneTitle(
            showsChat: true, chatTitle: nil, terminalTitle: "sessão (tmux)"
        )
        XCTAssertEqual(title, "sessão (tmux)")
    }

    /// Mesma lógica espelhada: sem terminal, cai pro chat mesmo com
    /// `showsChat == false`.
    func testSemTerminalCaiProTituloDoChatMesmoComShowsChatFalse() {
        let title = SessionDetailPaneLogic.paneTitle(
            showsChat: false, chatTitle: "sessão", terminalTitle: nil
        )
        XCTAssertEqual(title, "sessão")
    }
}
