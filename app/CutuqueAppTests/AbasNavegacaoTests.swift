import SwiftUI
import XCTest
@testable import CutuqueApp

/// Trava a parte pura do funil de seleção (12/08/2026 — achados 1-3 da revisão
/// adversarial da Task 5): `AbasNavegacao.selecoesOrfas` decide o que zerar
/// quando uma aba fecha, e `AbasNavegacao.listaMoraNoDetalhe` decide se a
/// `SessionListView` fica na coluna do meio ou vira o detalhe. Fixtures no
/// mesmo padrão de `AbasResolverTests` (`Machine`/`BoardTask`) e
/// `SessionNavigationLogicTests` (`Session` via `JSONDecoder.cutuque`, porque
/// `Session` só tem `init(from:)`).
final class AbasNavegacaoTests: XCTestCase {

    // MARK: - Fixtures

    private func sessao(id: String = "s1", machine: String = "macmini") -> Session {
        let json = """
        {"id":"\(id)","machine":"\(machine)","agent":"claude-code","title":"t",
         "state":"running","created_at":"2026-07-26T10:00:00Z",
         "updated_at":"2026-07-26T10:00:00Z","pane":null}
        """
        return try! JSONDecoder.cutuque.decode(Session.self, from: Data(json.utf8))
    }

    private func liveEntry(machine: String = "macmini", alvo: String = "main\t%1") -> LiveEntry {
        LiveEntry(machine: machine, session: DiscoveredSession(id: alvo, cwd: "/tmp", title: "t"))
    }

    private func maquina(nome: String = "macmini") -> Machine {
        Machine(name: nome, dest: "vx@192.0.2.50", port: 22, source: "app",
                hostFingerprint: "SHA256:abc", host: "192.0.2.50", identity: "vx",
                os: "Darwin 24.5.0", theme: nil, icon: nil)
    }

    private func card(id: String = "c1", titulo: String = "Fechar semana") -> BoardTask {
        BoardTask(id: id, title: titulo, column: "concluido", group: "g", session: "s")
    }

    // MARK: - selecoesOrfas — sessão

    /// Trava o caminho feliz: a aba da seleção `.session(...)` está entre as
    /// abas abertas (montada com `ChaveDeAba.para(_:)`, como o app monta) → não
    /// é órfã. Sem isto, o handler de `RootSplitView` zeraria uma seleção com
    /// aba viva a cada troca de aba, fechando a coluna de detalhe à toa.
    func testSelecaoDeSessaoComAbaAbertaNaoEhOrfa() {
        let s = sessao()
        let selecao = DetailSelection.session(s)
        let abas = [ChaveDeAba.para(selecao)]

        let orfas = AbasNavegacao.selecoesOrfas(abas: abas, sessao: selecao, maquina: nil, arquivo: nil)

        XCTAssertFalse(orfas.sessao)
        XCTAssertFalse(orfas.alguma)
    }

    /// O caso que a revisão relatou (achado 3): a aba `.chat` foi fechada (pelo
    /// `✕`, por `fecharOutras`/`fecharTodas`) e a seleção sobrou sozinha — é
    /// exatamente essa sujeira que `RootSplitView` precisa zerar.
    func testSelecaoDeSessaoComAbaFechadaEhOrfa() {
        let selecao = DetailSelection.session(sessao())

        let orfas = AbasNavegacao.selecoesOrfas(abas: [], sessao: selecao, maquina: nil, arquivo: nil)

        XCTAssertTrue(orfas.sessao)
        XCTAssertTrue(orfas.alguma)
    }

    // MARK: - selecoesOrfas — máquina

    func testSelecaoDeMaquinaComAbaAbertaNaoEhOrfa() {
        let m = maquina()
        let abas = [ChaveDeAba.maquina(m.name)]

        let orfas = AbasNavegacao.selecoesOrfas(abas: abas, sessao: nil, maquina: m, arquivo: nil)

        XCTAssertFalse(orfas.maquina)
        XCTAssertFalse(orfas.alguma)
    }

    func testSelecaoDeMaquinaComAbaFechadaEhOrfa() {
        let m = maquina()

        let orfas = AbasNavegacao.selecoesOrfas(abas: [], sessao: nil, maquina: m, arquivo: nil)

        XCTAssertTrue(orfas.maquina)
        XCTAssertTrue(orfas.alguma)
    }

    // MARK: - selecoesOrfas — card arquivado

    func testSelecaoDeArquivoComAbaAbertaNaoEhOrfa() {
        let c = card()
        let abas = [ChaveDeAba.arquivado(c.id)]

        let orfas = AbasNavegacao.selecoesOrfas(abas: abas, sessao: nil, maquina: nil, arquivo: c)

        XCTAssertFalse(orfas.arquivo)
        XCTAssertFalse(orfas.alguma)
    }

    func testSelecaoDeArquivoComAbaFechadaEhOrfa() {
        let c = card()

        let orfas = AbasNavegacao.selecoesOrfas(abas: [], sessao: nil, maquina: nil, arquivo: c)

        XCTAssertTrue(orfas.arquivo)
        XCTAssertTrue(orfas.alguma)
    }

    // MARK: - selecoesOrfas — nil e tipos diferentes

    /// Seleção `nil` nunca é órfã — órfã é estado PREENCHIDO sem aba, não
    /// ausência de seleção. Sem esta distinção, o handler de `RootSplitView`
    /// ficaria escrevendo `nil` em cima de `nil` a cada troca de aba.
    func testSelecoesNilNuncaSaoOrfasEAlgumaEhFalse() {
        let orfas = AbasNavegacao.selecoesOrfas(abas: [], sessao: nil, maquina: nil, arquivo: nil)

        XCTAssertFalse(orfas.sessao)
        XCTAssertFalse(orfas.maquina)
        XCTAssertFalse(orfas.arquivo)
        XCTAssertFalse(orfas.alguma)
    }

    /// Uma aba `.live` em "macmini" não salva a seleção `.session` no mesmo
    /// alvo: `ChaveDeAba` carrega `tipo` na identidade, então uma aba de tipo
    /// errado com máquina/alvo iguais NÃO conta como a aba da seleção. Sem
    /// este teste, um `contains` que comparasse só `machine`/`alvo` (ignorando
    /// `tipo`) passaria por engano — a mesma classe de bug que o `julgando` de
    /// `AbasResolverTests.testResolverNaoEncostaEmAbaDeSessao` existe pra
    /// impedir do outro lado (resolver x aba de sessão).
    func testAbaDeTipoDiferenteComMesmoAlvoNaoContaComoAbaDaSelecao() {
        let s = sessao(id: "sess-1", machine: "macmini")
        let selecao = DetailSelection.session(s)
        // Mesma machine/alvo da seleção, mas tipo `.live` — não é `ChaveDeAba.para(selecao)`.
        let abaDeOutroTipo = ChaveDeAba(tipo: .live, machine: "macmini", alvo: "sess-1")

        let orfas = AbasNavegacao.selecoesOrfas(abas: [abaDeOutroTipo], sessao: selecao, maquina: nil, arquivo: nil)

        XCTAssertTrue(orfas.sessao, "aba de outro tipo não pode mascarar a seleção como não-órfã")
    }

    /// Mesmo caso, do lado `.live`: uma aba `.chat` no mesmo par
    /// machine/alvo não guarda a seleção `.live`.
    func testAbaDeTipoDiferenteComMesmoAlvoNaoContaComoAbaDaSelecaoAoVivo() {
        let entry = liveEntry(machine: "macmini", alvo: "sess-1")
        let selecao = DetailSelection.live(entry)
        let abaDeOutroTipo = ChaveDeAba(tipo: .chat, machine: "macmini", alvo: "sess-1")

        let orfas = AbasNavegacao.selecoesOrfas(abas: [abaDeOutroTipo], sessao: selecao, maquina: nil, arquivo: nil)

        XCTAssertTrue(orfas.sessao)
    }

    // MARK: - listaMoraNoDetalhe

    /// Caso canônico: Sessões, nenhuma aba escolhida, `.doubleColumn` (retrato
    /// sem nada aberto) — é aqui que a lista precisa virar o detalhe.
    func testListaMoraNoDetalheNoCasoCanonico() {
        XCTAssertTrue(AbasNavegacao.listaMoraNoDetalhe(
            destino: .sessions, abaSelecionada: nil, colunas: .doubleColumn))
    }

    /// Este é o teste que fecha o achado MENOR da revisão da Task 5 ("a suíte
    /// passar 100% não prova que o achado 1 foi verificado"): com uma aba
    /// selecionada, mesmo em `.doubleColumn`, a lista NÃO pode ocupar o
    /// detalhe — é exatamente a condição que faltava antes do conserto e que
    /// produzia "lista | Nada aberto" com uma seleção órfã escondendo uma aba
    /// de verdade.
    func testListaMoraNoDetalheEhFalseComAbaSelecionada() {
        XCTAssertFalse(AbasNavegacao.listaMoraNoDetalhe(
            destino: .sessions, abaSelecionada: .board, colunas: .doubleColumn))
    }

    func testListaMoraNoDetalheEhFalseEmOutroDestino() {
        XCTAssertFalse(AbasNavegacao.listaMoraNoDetalhe(
            destino: .board, abaSelecionada: nil, colunas: .doubleColumn))
    }

    func testListaMoraNoDetalheEhFalseEmColunasAll() {
        XCTAssertFalse(AbasNavegacao.listaMoraNoDetalhe(
            destino: .sessions, abaSelecionada: nil, colunas: .all))
    }

    func testListaMoraNoDetalheEhFalseEmColunasDetailOnly() {
        XCTAssertFalse(AbasNavegacao.listaMoraNoDetalhe(
            destino: .sessions, abaSelecionada: nil, colunas: .detailOnly))
    }
}
