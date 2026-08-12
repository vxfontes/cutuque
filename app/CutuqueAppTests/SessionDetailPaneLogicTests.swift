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

    /// Entrada ao vivo abre no TERMINAL, seja qual for o `current` recebido.
    /// [12/08/2026] Até a G6 isto cobria "herdando de outra sessão", porque
    /// `paneMode` era estado compartilhado; com abas o modo é por aba, então
    /// o `current` aqui é só o valor com que a aba NOVA nasceu — mas
    /// `entryPaneMode` continua tendo que vencer ele do mesmo jeito. Isto já
    /// foi `.info` (paridade com o iPhone); a usuária testou no iPad e pediu
    /// o contrário em 2026-07-27, ver `entryPaneMode`.
    func testEntradaAoVivoAbreNoTerminal() {
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .info), .terminal)
        XCTAssertEqual(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .chat), .terminal)
    }

    /// Já no terminal, nada a corrigir — a função não pode devolver um valor
    /// "igual ao atual", senão o `onAppear` do pane escreveria no modo guardado
    /// a cada montagem à toa. [12/08/2026] Isto vale tanto para o `paneMode`
    /// compartilhado de antes da G6 quanto para o modo por aba de agora: o ✕
    /// do terminal leva pra `.info`, e nada remonta o pane pra desfazer isso
    /// — se `entryPaneMode` reescrevesse a cada `onAppear` redundante, o ✕
    /// perderia efeito na hora.
    func testJaNoTerminalNaoForcaNada() {
        XCTAssertNil(SessionDetailPaneLogic.entryPaneMode(
            hasChat: false, hasTerminal: true, hasInfo: true, current: .terminal))
    }

    /// O caminho de volta: sessão do registry NÃO tem informações ao vivo, e
    /// um `.info` — [12/08/2026] antes da G6, herdado de uma entrada ao vivo
    /// anterior via `paneMode` compartilhado; com abas, o valor com que a aba
    /// nova nasceu — viraria um painel vazio se não fosse corrigido. Cai pro
    /// chat.
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

    // MARK: - selectorSegments

    /// O pedido de 2026-07-27: numa entrada ao vivo, Terminal à ESQUERDA e
    /// Info à direita. A ordem é o contrato — a primeira aba é a que abre, e
    /// `entryPaneMode` tem que concordar (ver o teste do par, abaixo).
    func testEntradaAoVivoTemTerminalDepoisInfo() {
        let segments = SessionDetailPaneLogic.selectorSegments(
            hasChat: false, hasTerminal: true, hasInfo: true)
        XCTAssertEqual(segments.map(\.label), ["Terminal", "Info"])
        XCTAssertEqual(segments.map(\.mode), [.terminal, .info])
    }

    /// Sessão do registry rodando no tmux: `Chat | Terminal`, como sempre foi.
    func testSessaoDoRegistryNoTmuxTemChatDepoisTerminal() {
        let segments = SessionDetailPaneLogic.selectorSegments(
            hasChat: true, hasTerminal: true, hasInfo: false)
        XCTAssertEqual(segments.map(\.label), ["Chat", "Terminal"])
        XCTAssertEqual(segments.map(\.mode), [.chat, .terminal])
    }

    /// Sem terminal não há o que alternar — e o seletor vazio importa: um
    /// `ToolbarItem` em `.principal` sem conteúdo ocuparia o lugar do título.
    func testSessaoForaDoTmuxNaoTemSeletor() {
        XCTAssertTrue(SessionDetailPaneLogic.selectorSegments(
            hasChat: true, hasTerminal: false, hasInfo: false).isEmpty)
    }

    /// Só terminal (sem chat e sem info) também não alterna nada.
    func testSoTerminalNaoTemSeletor() {
        XCTAssertTrue(SessionDetailPaneLogic.selectorSegments(
            hasChat: false, hasTerminal: true, hasInfo: false).isEmpty)
    }

    /// O par tem que concordar: a aba que abre (`entryPaneMode`) precisa
    /// existir entre os segmentos, senão o segmentado aparece sem nada
    /// marcado. Cobre as oito combinações dos três "tem/não tem" × o valor
    /// com que a aba nasce (`current` — [12/08/2026] antes da G6 era o
    /// `paneMode` herdado de outra sessão; com abas é o modo inicial da aba
    /// nova, mas a mesma conta vale).
    func testAAbaQueAbreSempreExisteNoSeletor() {
        for hasChat in [true, false] {
            for hasTerminal in [true, false] {
                for hasInfo in [true, false] {
                    let segments = SessionDetailPaneLogic.selectorSegments(
                        hasChat: hasChat, hasTerminal: hasTerminal, hasInfo: hasInfo)
                    guard !segments.isEmpty else { continue }
                    for current in PaneMode.allCases {
                        let opens = SessionDetailPaneLogic.entryPaneMode(
                            hasChat: hasChat, hasTerminal: hasTerminal,
                            hasInfo: hasInfo, current: current) ?? current
                        XCTAssertTrue(
                            segments.contains { $0.mode == opens },
                            "abre em \(opens) mas o seletor só tem \(segments.map(\.mode)) "
                            + "(chat: \(hasChat), terminal: \(hasTerminal), info: \(hasInfo), atual: \(current))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - modoValido

    /// Modo possível: função identidade — devolve o mesmo valor recebido,
    /// sem consultar `selectorSegments`. Cobre os três modos, cada um numa
    /// seleção onde ele é legítimo.
    func testModoPossivelVoltaIntacto() {
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .chat, hasChat: true, hasTerminal: true, hasInfo: false), .chat)
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .terminal, hasChat: true, hasTerminal: true, hasInfo: false), .terminal)
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .info, hasChat: false, hasTerminal: true, hasInfo: true), .info)
    }

    /// Entrada ao vivo (chat: false, terminal: true, info: true) — o único
    /// modo impossível é `.chat`, e cai no primeiro segmento do seletor
    /// (`Terminal | Info`), que é `.terminal`. Mesmo resultado que
    /// `entryPaneMode` dá pra esta combinação (ver `testEntradaAoVivoAbreNoTerminal`).
    func testModoImpossivelNaEntradaAoVivoCaiProTerminal() {
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .chat, hasChat: false, hasTerminal: true, hasInfo: true), .terminal)
    }

    /// Sessão do registry no tmux (chat: true, terminal: true, info: false)
    /// — o único modo impossível é `.info`, e cai no primeiro segmento
    /// (`Chat | Terminal`), que é `.chat`. Mesmo resultado que `entryPaneMode`
    /// dá pra esta combinação (ver `testInfoHerdadoNumaSessaoDoRegistryViraChat`).
    func testModoImpossivelNaSessaoDoRegistryNoTmuxCaiProChat() {
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .info, hasChat: true, hasTerminal: true, hasInfo: false), .chat)
    }

    /// Sessão fora do tmux (chat: true, terminal: false, info: false) — dois
    /// modos impossíveis (`.terminal` e `.info`), e `selectorSegments` vem
    /// vazia (nada pra alternar, só chat). Cai no único modo possível: `.chat`.
    /// Mesmo resultado que `entryPaneMode` dá pra esta combinação (ver
    /// `testSemTerminalForcaChat`).
    func testModoImpossivelForaDoTmuxCaiProUnicoPossivel() {
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .terminal, hasChat: true, hasTerminal: false, hasInfo: false), .chat)
        XCTAssertEqual(SessionDetailPaneLogic.modoValido(
            .info, hasChat: true, hasTerminal: false, hasInfo: false), .chat)
    }

    /// O par com `selectorSegments`: o resultado de `modoValido`, pra
    /// QUALQUER modo guardado, está sempre entre os segmentos que o próprio
    /// seletor oferece — nunca um modo que o segmentado nem lista. É este
    /// teste que impede alguém de quebrar o par depois (mesma ideia de
    /// `testAAbaQueAbreSempreExisteNoSeletor`, agora para `modoValido`).
    /// Só se aplica quando HÁ segmentos: sem seletor (só um modo possível)
    /// não há "segmento marcado" a garantir.
    func testModoValidoSempreEntreOsSegmentosQuandoHaSegmentos() {
        for hasChat in [true, false] {
            for hasTerminal in [true, false] {
                for hasInfo in [true, false] {
                    let segments = SessionDetailPaneLogic.selectorSegments(
                        hasChat: hasChat, hasTerminal: hasTerminal, hasInfo: hasInfo)
                    guard !segments.isEmpty else { continue }
                    for modo in PaneMode.allCases {
                        let resultado = SessionDetailPaneLogic.modoValido(
                            modo, hasChat: hasChat, hasTerminal: hasTerminal, hasInfo: hasInfo)
                        XCTAssertTrue(
                            segments.contains { $0.mode == resultado },
                            "modoValido(\(modo)) devolveu \(resultado) mas o seletor só tem "
                            + "\(segments.map(\.mode)) (chat: \(hasChat), terminal: \(hasTerminal), info: \(hasInfo))"
                        )
                    }
                }
            }
        }
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
    /// `modoValido` já forçaria `showsChat == false` neste caso, mas mesmo que
    /// `showsChat` chegasse `true` por algum motivo, o título cai pro
    /// terminal em vez de virar `""` — nunca fica em branco à toa.
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
    /// em uso normal — `modoValido` sempre garante pelo menos um dos
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
