import XCTest
@testable import CutuqueApp

final class NovoTerminalFormTests: XCTestCase {

    private var completos: NovoTerminalCampos {
        NovoTerminalCampos(machine: "macbook", grupo: "defender", sessao: "mike",
                           pasta: "/Users/vanessa/dev/defender", agente: .claude)
    }

    func testCriarSoComTodosOsCamposValidos() {
        XCTAssertTrue(NovoTerminalFormLogic.podeCriar(completos))

        var semMaquina = completos; semMaquina.machine = ""
        XCTAssertFalse(NovoTerminalFormLogic.podeCriar(semMaquina))

        var grupoInvalido = completos; grupoInvalido.grupo = "defender:1"
        XCTAssertFalse(NovoTerminalFormLogic.podeCriar(grupoInvalido))

        var sessaoVazia = completos; sessaoVazia.sessao = ""
        XCTAssertFalse(NovoTerminalFormLogic.podeCriar(sessaoVazia))

        // Pasta tem de ser absoluta: é o que o hub aceita, e escolher pela lista de
        // dirs sempre dá absoluta — o caso relativo é digitação à mão.
        var pastaRelativa = completos; pastaRelativa.pasta = "dev/defender"
        XCTAssertFalse(NovoTerminalFormLogic.podeCriar(pastaRelativa))
    }

    /// D13: grupo novo não tem cerimônia. Os grupos conhecidos são só uma sugestão —
    /// digitar um nome que não existe É criar o grupo.
    ///
    /// Desvio do plano (12/08/2026): a chain E (que criaria `GrupoAoVivo`) roda em
    /// paralelo noutro worktree e o tipo não existe aqui. `gruposConhecidos` recebe
    /// `[String]` (nomes de grupo já dedupados na origem) em vez de `[GrupoAoVivo]`;
    /// a Task F3 faz o `map` no call site quando a chain E estiver mergeada.
    func testGruposConhecidosSaoSugestaoOrdenadaESemRepeticao() {
        XCTAssertEqual(NovoTerminalFormLogic.gruposConhecidos(["zima", "atlas", "zima"]),
                       ["atlas", "zima"])
        XCTAssertTrue(NovoTerminalFormLogic.podeCriar(
            NovoTerminalCampos(machine: "macbook", grupo: "grupo-que-nao-existe",
                               sessao: "s", pasta: "/tmp", agente: .terminal)))
    }

    /// D8 e D10: o terminal livre nasce sem agente; o codex é o `tmx cx`, com a flag.
    /// O valor bruto é o que vai no corpo do POST — o hub o usa como chave.
    func testValoresBrutosDosAgentes() {
        XCTAssertEqual(AgenteNovoTerminal.allCases.map(\.rawValue),
                       ["claude", "codex", "opencode", "terminal"])
    }
}
