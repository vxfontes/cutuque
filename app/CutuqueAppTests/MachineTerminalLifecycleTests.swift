import XCTest
@testable import CutuqueApp

final class MachineTerminalLifecycleTests: XCTestCase {
    func testAbaEmFocoNoTerminalTrabalha() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .terminal, naTela: true),
                       .trabalhar)
    }

    func testAbaVivaAtrasDeOutraSoSuspende() {
        // O shell, o `cd` e o comando rodando têm de sobreviver.
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .suspenso, pane: .terminal, naTela: true),
                       .suspender)
    }

    func testAbaQueDormeDesconecta() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .liberado, pane: .terminal, naTela: true),
                       .desconectar)
    }

    func testDesconectarVenceOPainelDeArquivos() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .liberado, pane: .files, naTela: false),
                       .desconectar)
    }

    func testPainelDeArquivosSuspendeSemDesconectar() {
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .files, naTela: true),
                       .suspender)
    }

    func testSubpastaEmpilhadaSuspendeSemDesconectar() {
        // `naTela: false` é a subpasta por cima: para de ler, socket segue aberto.
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: .ativo, pane: .terminal, naTela: false),
                       .suspender)
    }

    // MARK: - carregaArquivos (12/08/2026 — achado 2 da revisão adversarial da Task 5)

    func testAbaDeArquivosEmFocoCarrega() {
        // O único `true` da matriz: painel Arquivos, aba em foco, `.ativo`.
        XCTAssertTrue(MachineTerminalLifecycle.carregaArquivos(paneState: .ativo, pane: .files, naTela: true))
    }

    func testAbaDeArquivosAtrasDeOutraNaoCarrega() {
        // Aba viva mas atrás de outra (`.suspenso`) não busca: ela nem está sendo olhada.
        XCTAssertFalse(MachineTerminalLifecycle.carregaArquivos(paneState: .suspenso, pane: .files, naTela: true))
    }

    func testAbaDeArquivosDormindoPeloTetoNaoCarrega() {
        // `.liberado` é o teto de 6 (ou fechamento): não há por que gastar rede numa aba dormindo.
        XCTAssertFalse(MachineTerminalLifecycle.carregaArquivos(paneState: .liberado, pane: .files, naTela: true))
    }

    func testAbaDeArquivosForaDaTelaNaoCarrega() {
        // `naTela: false` é a subpasta empilhada por cima: quem está visível é o nível de baixo.
        XCTAssertFalse(MachineTerminalLifecycle.carregaArquivos(paneState: .ativo, pane: .files, naTela: false))
    }

    func testPainelDeTerminalNuncaCarregaArquivos() {
        // Terminal não é arquivo: mesmo em foco e `.ativo`, o portão é por painel.
        XCTAssertFalse(MachineTerminalLifecycle.carregaArquivos(paneState: .ativo, pane: .terminal, naTela: true))
    }

    func testAcaoDoTerminalECarregaArquivosNuncaLigamJuntas() {
        // Amarra o par: pro MESMO (paneState, pane, naTela), terminal trabalhando
        // e arquivos carregando nunca são `true` ao mesmo tempo — é o ponto de
        // existir um portão por painel, e não um único `isActive` compartilhado.
        let estado = (paneState: TerminalPaneState.ativo, naTela: true)

        // Com pane .terminal: o terminal trabalha, e arquivos NÃO carrega.
        XCTAssertEqual(MachineTerminalLifecycle.acao(paneState: estado.paneState, pane: .terminal, naTela: estado.naTela),
                       .trabalhar)
        XCTAssertFalse(MachineTerminalLifecycle.carregaArquivos(paneState: estado.paneState, pane: .terminal, naTela: estado.naTela))

        // Com pane .files: arquivos carrega, e o terminal NÃO trabalha (fica suspenso).
        XCTAssertTrue(MachineTerminalLifecycle.carregaArquivos(paneState: estado.paneState, pane: .files, naTela: estado.naTela))
        XCTAssertNotEqual(MachineTerminalLifecycle.acao(paneState: estado.paneState, pane: .files, naTela: estado.naTela),
                          .trabalhar)
    }
}
