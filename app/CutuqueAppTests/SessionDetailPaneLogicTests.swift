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

    // MARK: - entryPaneMode

    /// Sessão do registry com os dois painéis: nunca força nada — o usuário
    /// decide livremente entre chat e terminal.
    func testComOsDoisPaineisNaoForcaNada() {
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: true, hasInfo: false, current: .chat))
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: true, hasInfo: false, current: .terminal))
    }

    /// Sem chat e sem info (hipotético: só terminal) só pode mostrar terminal.
    func testSemChatForcaTerminal() {
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: false, current: .chat), .terminal)
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: false, current: .terminal))
    }

    /// Sem terminal (sessão fora do tmux) só pode mostrar chat — mesma lógica
    /// espelhada.
    func testSemTerminalForcaChat() {
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: false, hasInfo: false, current: .terminal), .chat)
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: false, hasInfo: false, current: .chat))
    }

    /// O pedido da usuária: entrada ao vivo abre nas INFORMAÇÕES, como no
    /// iPhone — mesmo vindo do terminal de outra sessão. `paneMode` é estado
    /// compartilhado, então sem isto a sessão ao vivo herdaria o painel da
    /// anterior e cairia direto no terminal, que é justamente o que ela
    /// reclamou.
    func testEntradaAoVivoAbreNasInformacoes() {
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .terminal), .info)
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .chat), .info)
    }

    /// Já nas informações, nada a corrigir — a função não pode devolver um
    /// valor "igual ao atual", senão o `onAppear` do pane escreveria em
    /// `nav.paneMode` a cada montagem à toa.
    func testJaNasInformacoesNaoForcaNada() {
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .info))
    }

    /// O caminho de volta: sessão do registry NÃO tem informações ao vivo, e
    /// um `.info` herdado de uma entrada ao vivo anterior viraria um painel
    /// vazio. Cai pro chat.
    func testInfoHerdadoNumaSessaoDoRegistryViraChat() {
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: true, hasInfo: false, current: .info), .chat)
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: true, hasTerminal: false, hasInfo: false, current: .info), .chat)
        // E numa seleção só-terminal (sem chat, sem info) o herdado vira
        // terminal, não chat.
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: false, current: .info), .terminal)
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

    /// Minor da revisão (rodada 2): sem chat NEM terminal (hoje inatingível
    /// em uso normal — `correctedPaneMode` sempre garante pelo menos um dos
    /// dois), o pane não quebra: devolve `""` em vez de crashar ou forçar um
    /// unwrap. Trava o comportamento pra não regredir silenciosamente se a
    /// lógica de seleção mudar.
    func testSemChatENemTerminalDevolveStringVazia() {
        let title = SessionDetailPaneLogic.paneTitle(showsChat: true, chatTitle: nil, terminalTitle: nil)
        XCTAssertEqual(title, "")
    }

    // MARK: - resolvedChatTitle

    /// Título ao vivo presente sempre vence — é o próprio conserto da rodada
    /// 3: o snapshot congelado de `nav.selection` não pode mais defasar o
    /// título visível do chat quando o hub muda `Session.title` depois da
    /// criação (`Registry.Reclaim`).
    func testTituloAoVivoPresenteVence() {
        let title = SessionDetailPaneLogic.resolvedChatTitle(live: "título novo (ao vivo)", fallback: "título antigo (snapshot)")
        XCTAssertEqual(title, "título novo (ao vivo)")
    }

    /// Sem título ao vivo ainda (preference não chegou / pane acabou de
    /// montar), cai pro fallback estático — nunca fica sem título à toa
    /// enquanto a primeira preference não chega.
    func testSemTituloAoVivoCaiProFallback() {
        let title = SessionDetailPaneLogic.resolvedChatTitle(live: nil, fallback: "título antigo (snapshot)")
        XCTAssertEqual(title, "título antigo (snapshot)")
    }

    /// Nenhum dos dois (sem seleção de chat): `nil` mesmo — quem decide o
    /// que fazer com isso é `paneTitle` (cai pro terminal, ou `""` no caso
    /// dos dois ausentes).
    func testSemNenhumDevolveNil() {
        XCTAssertNil(SessionDetailPaneLogic.resolvedChatTitle(live: nil, fallback: nil))
    }
}
