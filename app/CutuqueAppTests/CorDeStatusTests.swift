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

    /// [13/08/2026] A regra acima, sozinha, criava ambiguidade: `AppAccent`
    /// oferece **Laranja** e **Verde**, que são exatamente as cores de "precisa
    /// de você" e "concluído". Com Verde escolhido, uma sessão AINDA RODANDO
    /// ficava idêntica a uma concluída. Nenhum estado pode parecer outro —
    /// então quando a preferência colide, o `.running` mantém a própria cor.
    ///
    /// Este teste passa a valer por PAR (nunca iguais), não por valor fixo: é
    /// o que o teste anterior não conseguia pegar, porque usava `.purple`, uma
    /// cor que não colide com nada.
    func testRunningNuncaFicaIgualAOutroStatus() {
        for destaque in AppAccent.allCases.map(\.color) {
            let rodando = CorDeStatus.para(.running, destaque: destaque)
            for outro in [SessionState.needsYou, .done, .error, .idle] {
                XCTAssertNotEqual(rodando, CorDeStatus.para(outro, destaque: destaque),
                                  "com destaque \(destaque), 'rodando' ficou igual a '\(outro.label)'")
            }
        }
    }

    /// E a preferência continua valendo quando NÃO colide — a exceção acima não
    /// pode virar "o `.running` nunca segue o tema".
    func testDestaqueQueNaoColideSegueSendoUsado() {
        XCTAssertEqual(CorDeStatus.para(.running, destaque: .purple), Color.purple)
        XCTAssertEqual(CorDeStatus.para(.running, destaque: .indigo), Color.indigo)
    }
}
