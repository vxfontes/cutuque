import XCTest
@testable import CutuqueApp

/// A barra de abas com teclado (31/08/2026): andar entre abas, escolher pela
/// posição e desfazer um fechamento. Tudo em `OpenTabs`, que é struct de valor —
/// o mesmo motivo de `OpenTabsTests` rodar sem simulador vale aqui.
final class NavegacaoDeAbasTests: XCTestCase {

    private let a = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "%1")
    private let b = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "%2")
    private let c = ChaveDeAba(tipo: .chat, machine: "macmini", alvo: "s3")

    private func tresAbas() -> OpenTabs {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "A", conteudo: .pendente)
        t.abrir(chave: b, titulo: "B", conteudo: .pendente)
        t.abrir(chave: c, titulo: "C", conteudo: .pendente)
        return t
    }

    // MARK: andar entre abas (⌘⇧] / ⌘⇧[)

    func testProximaEAnteriorAndamUmaCasa() {
        var t = tresAbas()
        t.selecionar(a)
        t.irPara(passo: 1)
        XCTAssertEqual(t.selecionada, b)
        t.irPara(passo: -1)
        XCTAssertEqual(t.selecionada, a)
    }

    /// Circular: quem está na última e pede a próxima quer a primeira, não um
    /// atalho que não faz nada.
    func testAndarDaAVoltaNasDuasPontas() {
        var t = tresAbas()
        t.selecionar(c)
        t.irPara(passo: 1)
        XCTAssertEqual(t.selecionada, a)
        t.irPara(passo: -1)
        XCTAssertEqual(t.selecionada, c)
    }

    func testAndarSemAbaNenhumaNaoInventaSelecao() {
        var vazio = OpenTabs()
        vazio.irPara(passo: 1)
        XCTAssertNil(vazio.selecionada)
        XCTAssertTrue(vazio.abas.isEmpty)
    }

    /// Andar também conta como uso: a aba que ela alcançou pelo teclado tem de
    /// ficar viva, senão o ⌘⇧] derrubaria o pane que acabou de mostrar.
    ///
    /// Com três abas isto sozinho não prova nada — três é menos que
    /// `maxVivas`, então TODAS estão vivas de qualquer jeito e `.ativo` sai só
    /// da seleção. O teste continua aqui como leitura do caso simples; quem
    /// pega a regressão de verdade é o de baixo.
    func testAndarContaComoFocoParaOTetoDeVivas() {
        var t = tresAbas()
        t.selecionar(a)
        t.irPara(passo: 1)
        XCTAssertEqual(t.estado(de: b), .ativo)
        XCTAssertTrue(t.vivas.contains(b))
    }

    /// A regressão que importa: se `selecionar` parar de mexer em
    /// `ordemDeFoco`, andar até uma aba DORMENTE não a acorda, e o ⌘⇧] mostra
    /// uma aba escolhida cujo pane não existe. Só é observável com mais abas
    /// que `maxVivas`.
    func testAndarAcordaAbaDormente() {
        var t = OpenTabs()
        var chaves: [ChaveDeAba] = []
        for n in 0...OpenTabs.maxVivas {   // maxVivas + 1 abas
            let chave = ChaveDeAba(tipo: .chat, machine: "m", alvo: "s\(n)")
            chaves.append(chave)
            t.abrir(chave: chave, titulo: "S\(n)", conteudo: .pendente)
        }
        // A primeira aberta é a de foco mais antigo — nasce fora do teto.
        let dormente = chaves[0]
        XCTAssertFalse(t.vivas.contains(dormente), "a mais antiga tinha de estar dormente")

        // Chega nela andando para trás a partir da segunda.
        t.selecionar(chaves[1])
        t.irPara(passo: -1)

        XCTAssertEqual(t.selecionada, dormente)
        XCTAssertTrue(t.vivas.contains(dormente), "andar até ela tinha de acordá-la")
        XCTAssertEqual(t.estado(de: dormente), .ativo)
        XCTAssertEqual(t.vivas.count, OpenTabs.maxVivas, "acordar uma tem de dormir outra")
    }

    // MARK: escolher pela posição

    func testSelecionarPorIndice() {
        var t = tresAbas()
        t.selecionar(indice: 0)
        XCTAssertEqual(t.selecionada, a)
        t.selecionar(indice: 2)
        XCTAssertEqual(t.selecionada, c)
    }

    func testIndiceForaDaFaixaNaoMexeEmNada() {
        var t = tresAbas()
        t.selecionar(indice: 1)
        t.selecionar(indice: 9)
        XCTAssertEqual(t.selecionada, b)
        t.selecionar(indice: -1)
        XCTAssertEqual(t.selecionada, b)
    }

    // MARK: desfazer o fechamento (⌘⌥T)

    func testReabrirTrazAUltimaFechadaEAEscolhe() {
        var t = tresAbas()
        t.fechar(b)
        XCTAssertNil(t.aba(b))
        XCTAssertEqual(t.reabrirUltimaFechada(), b)
        XCTAssertEqual(t.aba(b)?.titulo, "B")
        XCTAssertEqual(t.selecionada, b)
    }

    /// D2 continua valendo no desfazer: reabrir devolve a ABA, nunca o pane.
    func testAbaReabertaVoltaPendenteENaoRecriaPane() {
        var t = OpenTabs()
        // `.board` aqui é só "um conteúdo já resolvido, diferente de pendente":
        // o que o teste afirma é que reabrir NÃO devolve conteúdo resolvido para
        // uma aba que depende de algo vivo, seja ele qual for.
        t.abrir(chave: a, titulo: "A", conteudo: .board)
        t.fechar(a)
        t.reabrirUltimaFechada()
        XCTAssertEqual(t.aba(a)?.conteudo, .pendente)
    }

    /// O Board não depende de nada vivo, então volta já resolvido — mesma regra
    /// de `conteudoInicial` na restauração do disco.
    func testBoardReabertoVoltaResolvido() {
        var t = OpenTabs()
        t.abrir(chave: .board, titulo: "Board", conteudo: .board)
        t.fechar(.board)
        t.reabrirUltimaFechada()
        XCTAssertEqual(t.aba(.board)?.conteudo, .board)
    }

    func testReabrirSemNadaFechadoNaoFazNada() {
        var t = tresAbas()
        XCTAssertNil(t.reabrirUltimaFechada())
        XCTAssertEqual(t.abas.count, 3)
    }

    func testDesfazerVoltaNaOrdemInversaDoFechamento() {
        var t = tresAbas()
        t.fechar(a)
        t.fechar(c)
        XCTAssertEqual(t.reabrirUltimaFechada(), c)
        XCTAssertEqual(t.reabrirUltimaFechada(), a)
        XCTAssertNil(t.reabrirUltimaFechada())
    }

    /// Já reaberta por outro caminho (ela clicou na sessão de novo): o ⌘⌥T pula
    /// e devolve a de antes, em vez de virar um atalho que não faz nada.
    func testReabrirPulaAQueJaVoltouSozinha() {
        var t = tresAbas()
        t.fechar(a)
        t.fechar(b)
        t.abrir(chave: b, titulo: "B de novo", conteudo: .pendente)
        XCTAssertEqual(t.reabrirUltimaFechada(), a)
    }

    func testFecharOutrasEmpilhaTodasParaDesfazer() {
        var t = tresAbas()
        t.fecharOutras(b)
        XCTAssertEqual(t.abas.count, 1)
        // Da esquerda para a direita, que é a ordem em que ⌘⌥T as devolve.
        XCTAssertEqual(t.reabrirUltimaFechada(), a)
        XCTAssertEqual(t.reabrirUltimaFechada(), c)
    }

    func testFecharTodasEmpilhaTodasParaDesfazer() {
        var t = tresAbas()
        t.fecharTodas()
        XCTAssertTrue(t.abas.isEmpty)
        XCTAssertEqual(t.fechadasRecentemente.count, 3)
        XCTAssertEqual(t.reabrirUltimaFechada(), a)
    }

    /// Uma aba fixa fechada na mão volta fixa: o pino é escolha dela, não
    /// consequência de estar aberta.
    func testAbaFixaVoltaFixa() {
        var t = tresAbas()
        t.fixar(c)
        t.fechar(c)
        t.reabrirUltimaFechada()
        XCTAssertEqual(t.aba(c)?.fixa, true)
    }

    /// A pilha é de arrependimento imediato, não histórico: tem fundo.
    func testPilhaDeDesfazerTemFundo() {
        var t = OpenTabs()
        let total = OpenTabs.maxFechadasLembradas + 5
        for n in 0..<total {
            let chave = ChaveDeAba(tipo: .chat, machine: "m", alvo: "s\(n)")
            t.abrir(chave: chave, titulo: "S\(n)", conteudo: .pendente)
            t.fechar(chave)
        }
        XCTAssertEqual(t.fechadasRecentemente.count, OpenTabs.maxFechadasLembradas)
    }

    /// Fechar e reabrir a MESMA aba várias vezes não pode empilhar cópias — a
    /// primeira já a traz de volta, e as outras seriam ⌘⌥T sem efeito visível.
    func testMesmaAbaNaoOcupaDuasVagasNaPilha() {
        var t = OpenTabs()
        for _ in 0..<3 {
            t.abrir(chave: a, titulo: "A", conteudo: .pendente)
            t.fechar(a)
        }
        XCTAssertEqual(t.fechadasRecentemente.count, 1)
    }

    /// A pilha é de memória e some com o app: restaurar do disco uma aba que ela
    /// fechou ontem seria o contrário do que fechar significa.
    func testPilhaNaoVaiParaODisco() {
        var t = tresAbas()
        t.fechar(a)
        XCTAssertFalse(t.paraPersistir.contains { $0.chave == a })
        XCTAssertTrue(OpenTabs.restaurando(t.paraPersistir).fechadasRecentemente.isEmpty)
    }
}
