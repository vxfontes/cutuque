import XCTest
@testable import CutuqueApp

/// Cobre a Fase 3 do "falha e conta" ([16/08/2026]): o hub passou a recusar o
/// `POST /sessions/{id}/resolve` com `409 {"error":"stale_state",
/// "current_state":"<vencedor>"}` quando a sessão já não está em `needs_you`
/// — o `Launcher.Resolve` virou CAS pra não sobrescrever um veredito terminal
/// que chegou no mesmo instante.
///
/// O que se prova aqui é a metade do app que a usuária enxerga: o TEXTO do
/// aviso. A decisão dela (16/08) foi "a linha volta E eu quero saber por quê",
/// então o texto precisa nomear o estado vencedor, não só dizer que deu erro.
///
/// Por que testar o texto e não a tela: o swipe aparece em TODA linha, em
/// qualquer estado, e com `allowsFullSwipe` arrastar até o fim já dispara o
/// "Concluir" — a recusa é caminho normal, não exceção rara. Antes desta leva
/// o call site era `try? await api.resolve(...)` depois de já ter removido a
/// linha: o erro sumia e a linha reaparecia sozinha no broadcast seguinte, sem
/// explicação nenhuma. Um teste sobre o texto é o que trava essa regressão.
final class ConcluirRecusadoTests: XCTestCase {

    /// O caso que motiva tudo: o estado vencedor aparece com o MESMO rótulo em
    /// pt-BR que a lista já usa na bolinha (`SessionState.label`) — se alguém
    /// trocar o rótulo num lugar só, a usuária lê dois nomes pra mesma coisa.
    ///
    /// A tabela cobre os cinco estados de propósito, mesmo os que o hub de hoje
    /// não devolve: desde [16/08/2026] `done` volta 200 (no-op idempotente, ver
    /// `TestResolveJaConcluidaEhNoOpIdempotente` no hub) e `needsYou` é o único
    /// `from` que o CAS aceita, então nenhum dos dois chega como `current_state`
    /// pelo caminho normal. Ainda assim o app precisa saber traduzi-los: hub
    /// mais antigo ainda em produção, ou uma futura mudança de contrato do lado
    /// de lá, não podem virar aviso sem nome na mão dela.
    func testTextoNomeiaOEstadoVencedorComORotuloDaLista() {
        let casos: [(SessionState, String)] = [
            (.error,    "não concluí: a sessão virou falhou"),
            (.done,     "não concluí: a sessão virou concluído"),
            (.idle,     "não concluí: a sessão virou ocioso"),
            (.running,  "não concluí: a sessão virou rodando"),
            (.needsYou, "não concluí: a sessão virou precisa de você"),
        ]
        for (estado, esperado) in casos {
            XCTAssertEqual(
                CutuqueError.textoDeConcluirRecusado(estado), esperado,
                "rótulo de \(estado.wireValue) divergiu do que a lista mostra"
            )
            // O texto do erro tipado tem que ser o MESMO que a função pura
            // devolve — é ele que a `resolve(_:)` joga no `notice`, via
            // `error.localizedDescription`.
            XCTAssertEqual(
                CutuqueError.concluirRecusado(atual: estado).errorDescription, esperado
            )
        }
    }

    /// Sem `current_state` no corpo, o app NÃO pode inventar um estado. Dois
    /// caminhos reais caem aqui: o `default` do `ResolveHandler` (que devolve
    /// `stale_state` genérico, sem estado) e um hub mais antigo, de antes desta
    /// leva. Nos dois, a mensagem é honesta em vez de nomear um vencedor falso.
    func testSemEstadoNoCorpoOTextoNaoInventaVencedor() {
        let texto = CutuqueError.textoDeConcluirRecusado(nil)
        XCTAssertEqual(texto, "não concluí: o estado da sessão mudou antes de eu conseguir")
        XCTAssertEqual(CutuqueError.concluirRecusado(atual: nil).errorDescription, texto)
        for estado in [SessionState.error, .done, .idle, .running, .needsYou] {
            XCTAssertFalse(
                texto.contains(estado.label),
                "sem current_state o aviso não pode nomear \(estado.wireValue)"
            )
        }
    }

    /// `.concluirRecusado` é caso SEPARADO de `.staleState` de propósito: os
    /// três `catch CutuqueError.staleState` do app (approve/deny/answer via
    /// `runAction`, e o `interrupt`) não podem passar a capturar a recusa do
    /// Concluir — são endpoints diferentes, e só este devolve `current_state`.
    func testNaoSeConfundeComOStaleStateDosOutrosEndpoints() {
        XCTAssertNotEqual(CutuqueError.concluirRecusado(atual: .error), .staleState)
        XCTAssertNotEqual(CutuqueError.concluirRecusado(atual: nil), .staleState)
        XCTAssertEqual(CutuqueError.staleState.errorDescription, "o estado mudou")
    }
}
