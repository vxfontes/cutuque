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
