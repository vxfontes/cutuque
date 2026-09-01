import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre o contrato novo da Task 8: `TerminalMirrorView` ganha um `isActive`
/// para parar o poll sem desmontar a view (decisão #19 — desmontar dispararia
/// `restoreSize()`, que só deve rodar ao fechar a sessão de verdade). O resto
/// da fiação (poll ligando/desligando, ZStack de opacidade no
/// `SessionDetailPane`) não tem lógica pura pra isolar em XCTest — o critério
/// de aceite real é o passo manual no simulador (Step 6 do brief da Task 8).
///
/// 12/08/2026 (Task D2): `isActive: Bool` virou `paneState: TerminalPaneState`.
/// O booleano não distinguia "troquei de aba" (mantém a largura do pane no
/// tmux) de "fechei o terminal" (devolve a largura) — no iPad o `✕` só trocava
/// `isActive`, nunca desmontava a view, e o `restoreSize()` (que vivia só no
/// `onDisappear`) nunca rodava: o pane ficava preso em `window-size manual`.
@MainActor
final class TerminalMirrorViewTests: XCTestCase {

    /// A chamada de 3 argumentos que já existe em `LiveDetailView` precisa
    /// continuar válida — `paneState` tem que ter default `.ativo`.
    func testIsActivoPadraoEhVerdadeiroQuandoOmitido() {
        let view = TerminalMirrorView(machine: "mac", target: "sess:0.0", title: "t")
        XCTAssertEqual(view.paneState, .ativo)
    }

    /// O `✕` do iPad não desmonta a view (ela fica montada para sempre) — só troca o
    /// modo do painel. Antes disso o `restoreSize()` vivia só no `onDisappear`, que
    /// nunca rodava ali: o pane ficava preso em `window-size manual` no PC.
    func testPainelFechadoNasceLiberado() {
        let view = TerminalMirrorView(machine: "mac", target: "sess:0.0", title: "t",
                                      paneState: .liberado)
        XCTAssertEqual(view.paneState, .liberado)
        XCTAssertFalse(view.paneState.fazPolling)
    }

    func testPainelDeTrasSuspendeSemDevolverLargura() {
        let view = TerminalMirrorView(machine: "mac", target: "sess:0.0", title: "t",
                                      paneState: .suspenso)
        XCTAssertFalse(view.paneState.fazPolling)
        XCTAssertFalse(TerminalPaneState.devolveLargura(de: .ativo, para: view.paneState))
    }
}

/// O portão que decide se o espelho segue o fim sozinho.
///
/// [01/09/2026] Entrou junto com a janela três vezes mais alta que a tela
/// (`TerminalGeometry.fatorDeContexto`). Antes dela a `ScrollView` do espelho
/// não tinha o que rolar e o pulo pro fim a cada quadro era inofensivo; com a
/// folga, o mesmo pulo arrancaria a leitura de volta até duas vezes por segundo.
final class PortaoDeAutoScrollTests: XCTestCase {

    /// Abrir o espelho é querer ver o agora.
    func testNasceSeguindoOFimESemPilula() {
        let portao = PortaoDeAutoScroll()
        XCTAssertTrue(portao.deveSeguirOFim)
        XCTAssertFalse(portao.mostraVoltarAoVivo)
    }

    func testArrastoVerticalSoltaEMostraAPilula() {
        var portao = PortaoDeAutoScroll()
        portao.arrastou(translation: CGSize(width: 2, height: -60))
        XCTAssertFalse(portao.deveSeguirOFim)
        XCTAssertTrue(portao.mostraVoltarAoVivo)
    }

    /// Gesto horizontal no espelho é seleção de texto, não leitura do passado.
    /// Soltar o portão ali seria desligar o "ao vivo" por engano — e sem a
    /// usuária ver o que fez.
    func testArrastoHorizontalNaoSolta() {
        var portao = PortaoDeAutoScroll()
        portao.arrastou(translation: CGSize(width: -80, height: 6))
        XCTAssertTrue(portao.deveSeguirOFim)
    }

    /// Toque parado que o `DragGesture` reporte com translação zerada não é
    /// arrasto: `abs(0) > abs(0)` é falso.
    func testTranslacaoZeradaNaoSolta() {
        var portao = PortaoDeAutoScroll()
        portao.arrastou(translation: .zero)
        XCTAssertTrue(portao.deveSeguirOFim)
    }

    /// Diagonal conta pelo eixo dominante — o dedo raramente sobe reto.
    func testDiagonalPredominantementeVerticalSolta() {
        var portao = PortaoDeAutoScroll()
        portao.arrastou(translation: CGSize(width: 30, height: -50))
        XCTAssertFalse(portao.deveSeguirOFim)
    }

    func testVoltarAoVivoPrendeDeNovoEEscondeAPilula() {
        var portao = PortaoDeAutoScroll()
        portao.arrastou(translation: CGSize(width: 0, height: 120))
        portao.voltarAoVivo()
        XCTAssertTrue(portao.deveSeguirOFim)
        XCTAssertFalse(portao.mostraVoltarAoVivo)
    }

    /// Sem isso a pílula viraria um botão que não faz nada quando o espelho já
    /// está no fim — pior que botão nenhum.
    func testPilulaEOInversoDeSeguirOFim() {
        var portao = PortaoDeAutoScroll()
        XCTAssertNotEqual(portao.deveSeguirOFim, portao.mostraVoltarAoVivo)
        portao.arrastou(translation: CGSize(width: 0, height: -20))
        XCTAssertNotEqual(portao.deveSeguirOFim, portao.mostraVoltarAoVivo)
    }
}

