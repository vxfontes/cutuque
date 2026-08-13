import XCTest
@testable import CutuqueApp

/// O `PATCH` desta tela manda `theme: ""` e "" significa MANTÉM — ele não sabe
/// dizer "volta ao padrão". Era a razão de aparência não existir ao editar
/// (comentário de 12/08). A razão continua verdadeira: o que muda é que a tela
/// passa a chamar TAMBÉM o `PUT /appearance`, que sabe. (13/08/2026)
final class AparenciaAoEditarTests: XCTestCase {
    func testNaoChamaAppearanceQuandoNadaMudou() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "dracula", iconeEscolhido: "server")
        XCTAssertNil(d)
    }

    func testVoltarAoPadraoEnviaVazio() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "server",
                                                temaEscolhido: "", iconeEscolhido: "")
        XCTAssertEqual(d?.tema, "")
        XCTAssertEqual(d?.icone, "")
    }

    /// O PUT leva os DOIS campos sempre: mandar só o que mudou apagaria o outro
    /// (vazio é escolha no `/appearance`, não "mantém").
    func testMudarSoOIconeAindaEnviaOTemaAtual() {
        let d = NewMachineView.Aparencia.decidir(temaAtual: "dracula", iconeAtual: "",
                                                temaEscolhido: "dracula", iconeEscolhido: "laptop")
        XCTAssertEqual(d?.tema, "dracula")
        XCTAssertEqual(d?.icone, "laptop")
    }

    // MARK: - Contra a fonte fresca (o que os 3 testes acima não cobriam)

    private func maquina(theme: String?, icon: String?) -> Machine {
        Machine(name: "servidor1", dest: "vx@192.0.2.50", port: 22, source: "app",
                hostFingerprint: "SHA256:abc", host: "192.0.2.50", identity: "vx",
                os: "Ubuntu 22.04", theme: theme, icon: icon)
    }

    /// [13/08/2026] O caso que apagava tema calado, e que os três testes acima
    /// NÃO conseguiam pegar porque alimentavam os quatro argumentos à mão, já
    /// coerentes por construção — o defeito estava todo na fiação em volta.
    ///
    /// Cenário: o hub tem "dracula" (posto pela sheet Informações, pelo Command
    /// Center ou por outro aparelho); a lista do app não recarregou, então a
    /// sheet semeou `tema = ""` e a seção mostra **Padrão**. A usuária só quer
    /// arrumar o ícone. Antes, isto mandava `theme: ""` no PUT — que substitui
    /// os dois campos — e "dracula" morria.
    func testIconeTocadoNaoApagaOTemaQueSoOHubConhece() {
        let d = NewMachineView.Aparencia.decidir(
            hub: maquina(theme: "dracula", icon: ""),
            temaEscolhido: "",            // semeado do snapshot velho
            iconeEscolhido: "server",
            temaTocado: false,            // ela não tocou no tema
            iconeTocado: true
        )
        XCTAssertEqual(d?.icone, "server")
        XCTAssertEqual(d?.tema, "dracula",
                       "campo intocado devolve o valor do HUB — nunca o que a sheet semeou")
    }

    /// O outro lado: quando ela MEXE no tema, "" é escolha de verdade ("volta ao
    /// padrão") e tem de ir. A guarda acima não pode virar "tema nunca muda".
    func testTemaTocadoParaVazioVoltaAoPadrao() {
        let d = NewMachineView.Aparencia.decidir(
            hub: maquina(theme: "dracula", icon: "server"),
            temaEscolhido: "", iconeEscolhido: "server",
            temaTocado: true, iconeTocado: false
        )
        XCTAssertEqual(d?.tema, "")
        XCTAssertEqual(d?.icone, "server")
    }

    /// Salvar só endereço/porta/identidade, sem tocar em aparência, não gasta
    /// PUT nenhum — mesmo com o snapshot da lista divergindo do hub.
    func testNadaTocadoNaoChamaAppearance() {
        let d = NewMachineView.Aparencia.decidir(
            hub: maquina(theme: "dracula", icon: "server"),
            temaEscolhido: "", iconeEscolhido: "",
            temaTocado: false, iconeTocado: false
        )
        XCTAssertNil(d)
    }

    /// `nil` do hub e `""` são a mesma coisa (padrão) — não pode virar PUT.
    func testNilDoHubEquivaleAVazio() {
        let d = NewMachineView.Aparencia.decidir(
            hub: maquina(theme: nil, icon: nil),
            temaEscolhido: "", iconeEscolhido: "",
            temaTocado: true, iconeTocado: true
        )
        XCTAssertNil(d)
    }

    // MARK: - Re-semear os pickers com a leitura fresca

    /// Campo intocado adota o valor do hub: é o que faz a seção parar de mostrar
    /// **Padrão** com "dracula" salvo.
    func testSemearAdotaOValorDoHubQuandoNaoTocado() {
        XCTAssertEqual(
            NewMachineView.Aparencia.semear(escolhaAtual: "", semeadoDe: "", doHub: "dracula"),
            "dracula"
        )
    }

    /// Mas se ela já escolheu algo, a releitura NÃO desfaz o toque dela na
    /// frente dos olhos dela — `preparar()` é async e chega depois do render.
    func testSemearNaoDesfazEscolhaJaFeita() {
        XCTAssertEqual(
            NewMachineView.Aparencia.semear(escolhaAtual: "nord", semeadoDe: "", doHub: "dracula"),
            "nord"
        )
    }
}
