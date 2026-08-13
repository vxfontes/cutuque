import SwiftUI
import XCTest
@testable import CutuqueApp

/// [13/08/2026] Ponto único e testável da regra "só o `.running` segue a cor
/// de destaque" — o resto do app varre `Color.accentColor` por
/// `@Environment(\.corDeDestaque)` direto na view, mas `SessionState.color` é
/// computed property de MODELO: não tem ambiente pra ler. `SessionListView`
/// já fazia isto à mão (`s == .running ? accentColor : s.color`); aqui vira
/// um lugar só.
final class CorDeStatusTests: XCTestCase {
    /// `.running` é o único status que segue a preferência: ele não é
    /// semântico (não é erro, não é sucesso, não é aviso) — é "a coisa está
    /// andando", que é o papel de destaque do app. Os outros três (`.error`,
    /// `.needsYou`, `.done`, `.idle`) são semânticos e NÃO mudam.
    func testSoORunningSegueADestaque() {
        let cor = Color.purple
        XCTAssertEqual(CorDeStatus.para(.running, destaque: cor), cor)
        XCTAssertEqual(CorDeStatus.para(.error, destaque: cor), SessionState.error.color)
        XCTAssertEqual(CorDeStatus.para(.needsYou, destaque: cor), SessionState.needsYou.color)
        XCTAssertEqual(CorDeStatus.para(.done, destaque: cor), SessionState.done.color)
        XCTAssertEqual(CorDeStatus.para(.idle, destaque: cor), SessionState.idle.color)
    }
}
