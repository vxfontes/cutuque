import XCTest
@testable import CutuqueApp

/// O modelo de abas do iPad. Três regras que a Vanessa travou (D1, D2):
/// aba de passagem é SUBSTITUÍDA ao tocar noutra coisa (modelo VS Code);
/// abrir um alvo que já está aberto FOCA a aba existente; nunca há duas abas
/// para o mesmo alvo.
final class OpenTabsTests: XCTestCase {

    private let a = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
    private let b = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%2")

    func testAbaDePassagemEhSubstituidaPelaProxima() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)          // passagem
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente)           // passagem
        XCTAssertEqual(t.abas.map(\.chave), [b], "a de passagem some no lugar da nova")
        XCTAssertEqual(t.selecionada, b)
    }

    func testAbaNormalNaoEhSubstituida() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente)
        XCTAssertEqual(t.abas.map(\.chave), [a, b])
    }

    /// Reabrir promove: é o equivalente do duplo clique do VS Code, e é o gesto
    /// que a Vanessa vai usar sem pensar quando quiser guardar a aba.
    func testReabrirUmaAbaDePassagemAPromoveENaoDuplica() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        XCTAssertEqual(t.abas.count, 1)
        XCTAssertEqual(t.abas[0].estilo, .normal)
        XCTAssertEqual(t.selecionada, a)
    }

    /// Abrir de novo NÃO troca o conteúdo vivo por um `.pendente` — senão focar
    /// uma aba restaurada e já reconciliada a jogaria de volta pro limbo.
    func testAbrirDeNovoPreservaOConteudoJaResolvido() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .board, estilo: .normal)
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        XCTAssertEqual(t.abas[0].conteudo, .board)
    }

    func testTituloEhAtualizadoQuandoAAbaJaExiste() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: a, titulo: "mike renomeada", conteudo: .pendente)
        XCTAssertEqual(t.abas[0].titulo, "mike renomeada")
    }

    func testSelecionarSobeAOrdemDeFoco() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: b, titulo: "aux", conteudo: .pendente, estilo: .normal)
        t.selecionar(a)
        XCTAssertEqual(t.selecionada, a)
        XCTAssertGreaterThan(t.abas[0].ordemDeFoco, t.abas[1].ordemDeFoco)
    }

    func testSelecionarChaveInexistenteNaoMudaNada() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        let antes = t
        t.selecionar(b)
        XCTAssertEqual(t, antes)
    }

    /// Uma aba por destino singular: Board aberto duas vezes é uma aba.
    func testDestinosSingularesNaoDuplicam() {
        var t = OpenTabs()
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        XCTAssertEqual(t.abas.count, 1)
    }

    func testChaveDeLiveSeparaMaquinasComMesmoNomeDeGrupo() {
        // Por que isto tem teste: é a razão de `identidade-pane-ao-vivo` ser
        // pré-requisito. Dois grupos "defender", um em cada máquina, com o mesmo
        // socket — se a chave não levasse a máquina, seriam a MESMA aba.
        let noMacbook = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/tmp/defender\t%1")
        let noWindows = ChaveDeAba(tipo: .live, machine: "windows", alvo: "/tmp/defender\t%1")
        XCTAssertNotEqual(noMacbook, noWindows)
    }

    // MARK: - G2: teto de 6 vivas e quem dorme

    /// D3: teto de 6 vivas, o resto dorme, e dormir = DEVOLVER A LARGURA. O
    /// mapeamento é exatamente o modelo de três estados da Task D1:
    ///   selecionada          → .ativo     (poll + largura aplicada)
    ///   viva, não escolhida  → .suspenso  (sem poll, largura mantida)
    ///   dormindo             → .liberado  (sem poll, largura devolvida)
    func testSeisVivasEOSetimoDorme() {
        var t = OpenTabs()
        let chaves = (1...7).map { ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%\($0)") }
        for c in chaves { t.abrir(chave: c, titulo: c.alvo, conteudo: .pendente, estilo: .normal) }

        XCTAssertEqual(t.selecionada, chaves[6])
        XCTAssertEqual(t.estado(de: chaves[6]), .ativo)
        // Os 5 seguintes mais recentes seguem vivos, mas suspensos.
        for c in chaves[2...5] { XCTAssertEqual(t.estado(de: c), .suspenso, "\(c.alvo)") }
        // O mais antigo dorme: 7 abertas, teto de 6.
        XCTAssertEqual(t.estado(de: chaves[0]), .liberado)
        XCTAssertEqual(t.vivas.count, OpenTabs.maxVivas)
    }

    /// Quem dorme é o menos usado, não o mais antigo na barra: focar acorda.
    func testFocarAcordaEEmpurraOMenosUsadoParaDormir() {
        var t = OpenTabs()
        let chaves = (1...7).map { ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%\($0)") }
        for c in chaves { t.abrir(chave: c, titulo: c.alvo, conteudo: .pendente, estilo: .normal) }
        XCTAssertEqual(t.estado(de: chaves[0]), .liberado)

        t.selecionar(chaves[0])
        XCTAssertEqual(t.estado(de: chaves[0]), .ativo)
        XCTAssertEqual(t.estado(de: chaves[1]), .liberado, "o que sobrou de menos usado passa a dormir")
    }

    // NOTA (desvio G2, 12/08/2026): `testFixarNaoImpedeDeDormir` foi escrito na
    // Task G3, não aqui. `fixar(_:)` ainda não existe nesta task, e diferente de
    // uma asserção que falha, um método inexistente é ERRO DE COMPILAÇÃO — quebra
    // a suíte inteira do `OpenTabsTests`, não só este teste. O próprio plano
    // (G2, Step 4) prevê essa alternativa: "se preferir, escreva-o na G3".

    func testEstadoDeAbaQueNaoExisteEhLiberado() {
        let t = OpenTabs()
        XCTAssertEqual(t.estado(de: a), .liberado)
    }

    // MARK: - G3: fixar, fechar, fechar outras, fechar todas

    /// Fixar protege de fechar, NÃO de dormir. São eixos diferentes de propósito:
    /// dormir é custo de tmux (largura + poll), fixar é intenção de navegação.
    /// Quem "melhorar" isto acordando as fixas fura o teto de 6.
    func testFixarNaoImpedeDeDormir() {
        var t = OpenTabs()
        let chaves = (1...7).map { ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%\($0)") }
        for c in chaves { t.abrir(chave: c, titulo: c.alvo, conteudo: .pendente, estilo: .normal) }
        t.fixar(chaves[0])
        XCTAssertEqual(t.estado(de: chaves[0]), .liberado)
    }

    func testFecharEscolheAVizinhaDaEsquerda() {
        var t = OpenTabs()
        let c = (1...3).map { ChaveDeAba(tipo: .live, machine: "m", alvo: "/s\t%\($0)") }
        for k in c { t.abrir(chave: k, titulo: k.alvo, conteudo: .pendente, estilo: .normal) }
        t.selecionar(c[1])
        t.fechar(c[1])
        XCTAssertEqual(t.abas.map(\.chave), [c[0], c[2]])
        XCTAssertEqual(t.selecionada, c[0], "a vizinha da esquerda; sem esquerda, a da direita")
    }

    func testFecharAPrimeiraEscolheADireita() {
        var t = OpenTabs()
        let c = (1...2).map { ChaveDeAba(tipo: .live, machine: "m", alvo: "/s\t%\($0)") }
        for k in c { t.abrir(chave: k, titulo: k.alvo, conteudo: .pendente, estilo: .normal) }
        t.selecionar(c[0])
        t.fechar(c[0])
        XCTAssertEqual(t.selecionada, c[1])
    }

    func testFecharUmaQueNaoEstaEmFocoNaoMudaOFoco() {
        var t = OpenTabs()
        let c = (1...2).map { ChaveDeAba(tipo: .live, machine: "m", alvo: "/s\t%\($0)") }
        for k in c { t.abrir(chave: k, titulo: k.alvo, conteudo: .pendente, estilo: .normal) }
        t.selecionar(c[1])
        t.fechar(c[0])
        XCTAssertEqual(t.selecionada, c[1])
    }

    /// D2: fechar a última é permitido e deixa o painel vazio — o estado sem
    /// nenhuma aba é legítimo, não um caso de erro. Quem "consertar" isso
    /// recusando o fechamento tira da Vanessa a única forma de zerar a tela.
    func testFecharAUltimaDeixaNadaSelecionado() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.fechar(a)
        XCTAssertTrue(t.abas.isEmpty)
        XCTAssertNil(t.selecionada)
    }

    func testFecharOutrasPoupaAFixaEAPropria() {
        var t = OpenTabs()
        let c = (1...4).map { ChaveDeAba(tipo: .live, machine: "m", alvo: "/s\t%\($0)") }
        for k in c { t.abrir(chave: k, titulo: k.alvo, conteudo: .pendente, estilo: .normal) }
        t.fixar(c[0])
        t.fecharOutras(c[2])
        XCTAssertEqual(Set(t.abas.map(\.chave)), Set([c[0], c[2]]))
        XCTAssertEqual(t.selecionada, c[2])
    }

    func testFecharTodasPoupaAsFixasEEscolheAPrimeiraQueSobrou() {
        var t = OpenTabs()
        let c = (1...3).map { ChaveDeAba(tipo: .live, machine: "m", alvo: "/s\t%\($0)") }
        for k in c { t.abrir(chave: k, titulo: k.alvo, conteudo: .pendente, estilo: .normal) }
        t.fixar(c[1])
        t.fecharTodas()
        XCTAssertEqual(t.abas.map(\.chave), [c[1]])
        XCTAssertEqual(t.selecionada, c[1])
    }

    func testFecharTodasSemNenhumaFixaZeraTudo() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.fecharTodas()
        XCTAssertTrue(t.abas.isEmpty)
        XCTAssertNil(t.selecionada)
    }

    /// Fixar uma aba de passagem também a promove: senão a próxima coisa aberta
    /// substituiria a aba que a Vanessa acabou de mandar ficar.
    func testFixarPromoveAAbaDePassagem() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente)
        t.fixar(a)
        XCTAssertEqual(t.abas[0].estilo, .normal)
        XCTAssertTrue(t.abas[0].fixa)

        t.abrir(chave: b, titulo: "aux", conteudo: .pendente)
        XCTAssertEqual(t.abas.count, 2)
    }
}
