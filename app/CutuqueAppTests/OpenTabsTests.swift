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

    // MARK: - G4: persistência e reconciliação

    /// D2: as abas voltam ao reabrir o app, e uma aba cujo pane morreu vira
    /// AVISO — nunca uma tentativa de recriar o pane. Recriar seria abrir sessão
    /// de tmux sem a Vanessa pedir, no boot do app.
    func testRoundTripDaPersistencia() {
        var t = OpenTabs()
        t.abrir(chave: a, titulo: "mike", conteudo: .pendente, estilo: .normal)
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        t.fixar(a)

        let dados = try! JSONEncoder().encode(t.paraPersistir)
        let salvas = try! JSONDecoder().decode([AbaPersistida].self, from: dados)
        let voltou = OpenTabs.restaurando(salvas)

        XCTAssertEqual(voltou.abas.map(\.chave), [a, .board])
        XCTAssertEqual(voltou.abas.map(\.titulo), ["mike", "Board"])
        XCTAssertTrue(voltou.abas[0].fixa)
        XCTAssertEqual(voltou.selecionada, a, "restaura escolhendo a primeira")
        // Sessão (`.live`) não tem conteúdo antes da reconciliação: o pane não
        // é recriado no boot. Board é a exceção [12/08/2026 — abas globais]:
        // ele não depende de nada do hub, então já nasce `.board` em
        // `conteudoInicial`, sem esperar reconciliação nenhuma.
        XCTAssertEqual(voltou.abas.map(\.conteudo), [.pendente, .board])
        // E nada de passagem: aba restaurada é aba que a Vanessa quis guardar.
        XCTAssertTrue(voltou.abas.allSatisfy { $0.estilo == .normal })
    }

    func testReconciliarResolveAsVivasEMarcaAsMortas() {
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: a, titulo: "mike", fixa: false),
            AbaPersistida(chave: b, titulo: "aux", fixa: false),
        ])
        t.reconciliar(vivas: [a: .board])   // `.board` aqui é só um conteúdo qualquer não-pendente
        XCTAssertEqual(t.aba(a)?.conteudo, .board)
        XCTAssertEqual(t.aba(b)?.conteudo, .morta, "existia, não existe mais → aviso")
        XCTAssertEqual(t.abas.count, 2, "a aba morta FICA na barra; ela é o aviso")
    }

    /// Reconciliar de novo depois de a sessão voltar (hub reiniciou, ssh caiu e
    /// voltou) tem de RESSUSCITAR a aba: `morta` é um estado da vez, não uma
    /// sentença. Sem isto, um blip de rede deixa a barra cheia de avisos até a
    /// Vanessa fechar cada um à mão.
    func testAbaMortaVoltaAVidaSeOAlvoReaparecer() {
        var t = OpenTabs.restaurando([AbaPersistida(chave: a, titulo: "mike", fixa: false)])
        t.reconciliar(vivas: [:])
        XCTAssertEqual(t.aba(a)?.conteudo, .morta)
        t.reconciliar(vivas: [a: .board])
        XCTAssertEqual(t.aba(a)?.conteudo, .board)
    }

    /// Board não depende de nada vivo: reconciliar não pode matá-lo. [Nota
    /// 12/08/2026 — abas globais: Arquivo SAIU desta afirmação — ele passou a
    /// depender do retrato do `AbasResolver`, ver
    /// `testMaquinaAusenteMorreSoQuandoOTipoEstaSendoJulgado` e a família
    /// `testJulgandoNaoAfetaBoardMasAgoraAfetaMaquinaEArquivado`.]
    func testDestinosQueNaoDependemDeTmuxNaoMorrem() {
        var t = OpenTabs()
        t.abrir(chave: .board, titulo: "Board", conteudo: .board, estilo: .normal)
        t.reconciliar(vivas: [:])
        XCTAssertEqual(t.aba(.board)?.conteudo, .board)
    }

    func testRestaurarNadaDaUmModeloVazio() {
        let t = OpenTabs.restaurando([])
        XCTAssertTrue(t.abas.isEmpty)
        XCTAssertNil(t.selecionada)
    }

    // MARK: - G6: `julgando` (12/08/2026 — críticos #A e #B da revisão adversarial)
    //
    // O registry (`.chat`) e os panes do tmux (`.live`) chegam em dois tempos
    // independentes; `julgando` diz explicitamente sobre qual FONTE o chamador
    // tem retrato agora, pra ausência na outra não parecer morte.

    /// Crítico #A: com retrato só do registry, uma aba `.live` ausente NÃO
    /// morre — é o cold start em que o REST completa antes do poll de vivas,
    /// e a aba `.live` restaurada do disco (terminal tmux de verdade, vivo no
    /// hub) ainda não teve chance de aparecer em `vivas`.
    func testJulgandoSoChatNaoMataAbaLiveAusenteMasMataChatAusente() {
        let liveChave = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
        let chatChave = ChaveDeAba(tipo: .chat, machine: "macbook", alvo: "s1")
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: liveChave, titulo: "term", fixa: false),
            AbaPersistida(chave: chatChave, titulo: "chat", fixa: false),
        ])
        t.reconciliar(vivas: [:], julgando: [.chat])
        XCTAssertEqual(t.aba(liveChave)?.conteudo, .pendente, "sem retrato dos vivos: não julga")
        XCTAssertEqual(t.aba(chatChave)?.conteudo, .morta, "retrato do registry: ausência mata")
    }

    /// O simétrico: com retrato só dos vivos, uma aba `.chat` ausente NÃO
    /// morre, mas uma `.live` ausente morre.
    func testJulgandoSoLiveNaoMataAbaChatAusenteMasMataLiveAusente() {
        let liveChave = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
        let chatChave = ChaveDeAba(tipo: .chat, machine: "macbook", alvo: "s1")
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: liveChave, titulo: "term", fixa: false),
            AbaPersistida(chave: chatChave, titulo: "chat", fixa: false),
        ])
        t.reconciliar(vivas: [:], julgando: [.live])
        XCTAssertEqual(t.aba(chatChave)?.conteudo, .pendente, "sem retrato do registry: não julga")
        XCTAssertEqual(t.aba(liveChave)?.conteudo, .morta, "retrato dos vivos: ausência mata")
    }

    /// Crítico #B: com os DOIS tipos julgados e dicionário vazio, as duas
    /// ainda morrem — o comportamento antigo continua disponível quando o app
    /// REALMENTE tem retrato das duas fontes. Não existe mais estado em que a
    /// reconciliação fique desligada para sempre.
    func testJulgandoOsDoisTiposComDicionarioVazioMataAsDuas() {
        let liveChave = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
        let chatChave = ChaveDeAba(tipo: .chat, machine: "macbook", alvo: "s1")
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: liveChave, titulo: "term", fixa: false),
            AbaPersistida(chave: chatChave, titulo: "chat", fixa: false),
        ])
        t.reconciliar(vivas: [:], julgando: [.live, .chat])
        XCTAssertEqual(t.aba(liveChave)?.conteudo, .morta)
        XCTAssertEqual(t.aba(chatChave)?.conteudo, .morta)
    }

    /// Chamada sem o parâmetro (default = todos os tipos) preserva o
    /// significado antigo — prova que os testes e chamadores que já existiam
    /// não mudaram de comportamento com este parâmetro novo.
    func testReconciliarSemParametroContinuaMatandoTudoQueDependeDeAlgoVivo() {
        let liveChave = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
        let chatChave = ChaveDeAba(tipo: .chat, machine: "macbook", alvo: "s1")
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: liveChave, titulo: "term", fixa: false),
            AbaPersistida(chave: chatChave, titulo: "chat", fixa: false),
        ])
        t.reconciliar(vivas: [:])
        XCTAssertEqual(t.aba(liveChave)?.conteudo, .morta)
        XCTAssertEqual(t.aba(chatChave)?.conteudo, .morta)
    }

    /// [Reescrito em 12/08/2026 — abas globais] Antes desta leva, Board,
    /// Máquina e Arquivo eram TODOS imunes a `julgando`, porque nenhum deles
    /// dependia de algo vivo. Isso mudou pela metade: Máquina e Arquivo agora
    /// têm uma autoridade de verdade (o `AbasResolver`, Task 3) que pode
    /// atestar ausência, então com os dois tipos julgados e `vivas` vazio eles
    /// morrem — é o mesmo comportamento que
    /// `testMaquinaAusenteMorreSoQuandoOTipoEstaSendoJulgado` prova em
    /// detalhe. Só Board continua imune: ele nasce resolvido em
    /// `conteudoInicial` e não existe autoridade que possa dizer que ele não
    /// existe.
    func testJulgandoNaoAfetaBoardMasAgoraAfetaMaquinaEArquivado() {
        let maquinaChave = ChaveDeAba.maquina("mike")
        let arquivadoChave = ChaveDeAba.arquivado("t1")
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: .board, titulo: "Board", fixa: false),
            AbaPersistida(chave: maquinaChave, titulo: "mike", fixa: false),
            AbaPersistida(chave: arquivadoChave, titulo: "t1", fixa: false),
        ])
        t.reconciliar(vivas: [:], julgando: [.board, .maquina, .arquivado, .live, .chat])
        XCTAssertEqual(t.aba(.board)?.conteudo, .board, "nasce resolvido; nada o mata por ausência")
        XCTAssertEqual(t.aba(maquinaChave)?.conteudo, .morta, "agora depende do retrato do AbasResolver")
        XCTAssertEqual(t.aba(arquivadoChave)?.conteudo, .morta, "idem")
    }

    /// A substituição de conteúdo NÃO depende do julgamento: chave presente
    /// em `vivas` é adotada mesmo quando o tipo dela não está no conjunto
    /// julgado.
    func testConteudoEhAdotadoParaChavePresenteMesmoQuandoTipoNaoEstaSendoJulgado() {
        let liveChave = ChaveDeAba(tipo: .live, machine: "macbook", alvo: "/s\t%1")
        var t = OpenTabs.restaurando([AbaPersistida(chave: liveChave, titulo: "term", fixa: false)])
        t.reconciliar(vivas: [liveChave: .board], julgando: [.chat])
        XCTAssertEqual(t.aba(liveChave)?.conteudo, .board, "presença adota sempre, independente do julgamento")
    }

    // MARK: - Task 2 (abas globais, 12/08/2026): símbolo por tipo, Board nasce
    // resolvido, máquina/arquivo julgáveis.
    //
    // Antes desta task, `dependeDeAlgoVivo` devolvia `false` para `.board`,
    // `.maquina` e `.arquivado`, e ninguém resolvia o conteúdo delas: uma aba
    // restaurada do disco nascia `.pendente` e girava `ProgressView` pra
    // sempre. Board se resolve sozinho (não depende de nada do hub); máquina
    // e arquivo passam a ter uma autoridade (o `AbasResolver`, Task 3), e é a
    // disciplina do `julgando` que impede a ausência de matá-las antes do
    // retrato dessa autoridade chegar.

    func testAbaDeBoardRestauradaNasceResolvida() {
        let salvas = [AbaPersistida(chave: .board, titulo: "Board", fixa: false)]
        let t = OpenTabs.restaurando(salvas)
        XCTAssertEqual(t.abas.first?.conteudo, .board,
                       "Board não depende de nada do hub — nascer .pendente giraria ProgressView pra sempre")
    }

    func testAbaDeMaquinaRestauradaNascePendente() {
        let salvas = [AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false)]
        let t = OpenTabs.restaurando(salvas)
        XCTAssertEqual(t.abas.first?.conteudo, .pendente,
                       "máquina precisa da Machine de verdade (tema, ícone) — quem resolve é o AbasResolver")
    }

    func testMaquinaAusenteMorreSoQuandoOTipoEstaSendoJulgado() {
        var t = OpenTabs.restaurando([
            AbaPersistida(chave: .maquina("macmini"), titulo: "macmini", fixa: false)
        ])
        // Retrato só do registry: a aba de máquina NÃO pode morrer por ausência.
        t.reconciliar(vivas: [:], julgando: [.chat])
        XCTAssertEqual(t.abas.first?.conteudo, .pendente)

        // Retrato das máquinas, e ela não está lá: agora sim.
        t.reconciliar(vivas: [:], julgando: [.maquina])
        XCTAssertEqual(t.abas.first?.conteudo, .morta)
    }

    func testAbaDeBoardNuncaMorrePorAusencia() {
        var t = OpenTabs.restaurando([AbaPersistida(chave: .board, titulo: "Board", fixa: false)])
        t.reconciliar(vivas: [:])   // padrão: julga TODOS os tipos
        XCTAssertEqual(t.abas.first?.conteudo, .board,
                       "Board é tela do hub, não pane: não há autoridade que possa dizer que ele não existe")
    }

    func testTodoTipoTemSimbolo() {
        for tipo in TipoDeAba.allCases {
            XCTAssertFalse(tipo.simbolo.isEmpty)
        }
    }
}
