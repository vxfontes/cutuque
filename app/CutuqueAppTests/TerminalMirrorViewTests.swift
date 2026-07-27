import SwiftUI
import XCTest
@testable import CutuqueApp

/// Cobre o contrato novo da Task 8: `TerminalMirrorView` ganha um `isActive`
/// para parar o poll sem desmontar a view (decisão #19 — desmontar dispararia
/// `restoreSize()`, que só deve rodar ao fechar a sessão de verdade). O resto
/// da fiação (poll ligando/desligando, ZStack de opacidade no
/// `SessionDetailPane`) não tem lógica pura pra isolar em XCTest — o critério
/// de aceite real é o passo manual no simulador (Step 6 do brief da Task 8).
@MainActor
final class TerminalMirrorViewTests: XCTestCase {

    /// A chamada de 3 argumentos que já existe em `LiveDetailView` precisa
    /// continuar válida — `isActive` tem que ter default `true`.
    func testIsActivoPadraoEhVerdadeiroQuandoOmitido() {
        let view = TerminalMirrorView(machine: "mac", target: "sess:0.0", title: "t")
        XCTAssertTrue(view.isActive)
    }

    func testIsActivoPodeSerDesligadoExplicitamente() {
        let view = TerminalMirrorView(machine: "mac", target: "sess:0.0", title: "t", isActive: false)
        XCTAssertFalse(view.isActive)
    }
}
