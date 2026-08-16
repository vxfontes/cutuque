import XCTest
@testable import CutuqueApp

@MainActor
final class ResizeDebouncerTests: XCTestCase {

    /// O caso que motiva tudo: arrastar o divisor gera uma rajada de tamanhos.
    /// Só o último pode virar POST.
    func testRajadaDeTamanhosViraUmUnicoResize() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var enviados: [(Int, Int)] = []

        for cols in 60...70 {
            debouncer.schedule(cols: cols, rows: 40) { c, r in enviados.append((c, r)) }
        }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(enviados.count, 1)
        XCTAssertEqual(enviados.first?.0, 70)
        XCTAssertEqual(enviados.first?.1, 40)
    }

    func testTamanhoRepetidoNaoReenvia() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var chamadas = 0

        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        try? await Task.sleep(for: .milliseconds(200))
        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(chamadas, 1)
    }

    func testTamanhosDiferentesEmMomentosDiferentesEnviamOsDois() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(20))
        var enviados: [Int] = []

        debouncer.schedule(cols: 88, rows: 40) { c, _ in enviados.append(c) }
        try? await Task.sleep(for: .milliseconds(200))
        debouncer.schedule(cols: 146, rows: 40) { c, _ in enviados.append(c) }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(enviados, [88, 146])
    }

    func testCancelarImpedeOEnvioPendente() async {
        let debouncer = ResizeDebouncer(delay: .milliseconds(50))
        var chamadas = 0

        debouncer.schedule(cols: 88, rows: 40) { _, _ in chamadas += 1 }
        debouncer.cancel()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(chamadas, 0)
    }

    /// Regressão da Task 8 (revisão, Critical 2): o `Task` pendente de
    /// `schedule()` não pode reter `self` por forte — se o `ResizeDebouncer`
    /// for liberado (dono saiu de cena) SEM que ninguém chame `cancel()`
    /// explicitamente, o resize atrasado tem que morrer junto, nunca disparar
    /// depois. Aqui o `debouncer` só existe dentro do `do {}`; ninguém chama
    /// `cancel()`. Com `self` forte no `schedule()`, o próprio `Task`
    /// pendente mantém o objeto vivo (ciclo `self → pending → closure →
    /// self`) e o `send` dispara mesmo assim — por isso este teste é RED
    /// antes da correção. Com `[weak self]`, o objeto é liberado de verdade
    /// ao sair do escopo, o `Task` acorda com `self` nil e desiste sem
    /// enviar.
    func testObjetoLiberadoSemCancelarNaoEnviaODelayAtrasado() async {
        var chamadas = 0
        do {
            let debouncer = ResizeDebouncer(delay: .milliseconds(30))
            debouncer.schedule(cols: 100, rows: 40) { _, _ in chamadas += 1 }
            // `debouncer` sai de escopo aqui — de propósito, sem `cancel()`.
        }
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(chamadas, 0)
    }
}

/// `PollPacer` depois da reescrita do card 33fcfae34fe2a744 (rampa contínua,
/// piso de 500 ms, limiar de ociosidade de 60 s). O que se prova aqui é
/// exatamente o que a Vanessa reclamou e o que ela pediu: a rampa não pode
/// ser um degrau de dois valores, uma mudança de tela tem que derrubar o
/// intervalo ao piso NA HORA, e o limiar até virar "parado" agora é 1 minuto.
final class PollPacerTests: XCTestCase {

    /// Tela recém-mudada (`quietFor == 0`) começa no PISO, não mais no antigo
    /// "fast" de 1,5 s — esse valor nunca era atingido de verdade (defeito 1
    /// do card), então o número certo para "tela em movimento" é o piso novo.
    func testComecaNoPiso() {
        XCTAssertEqual(PollPacer().interval, .milliseconds(500))
    }

    /// A prova central do defeito 4: a rampa é CONTÍNUA, não um degrau de
    /// dois valores. Amostra pontos crescentes de `quietFor` e confirma que o
    /// intervalo sobe estritamente a cada um deles — se fosse degrau, vários
    /// destes pontos cairiam no mesmo valor (piso OU teto, nunca outra coisa).
    func testRampaSobeProgressivamenteENaoEmDegrau() {
        func intervalo(apos quietFor: TimeInterval) -> Duration {
            var pacer = PollPacer()
            pacer.record(changed: false, elapsed: quietFor)
            return pacer.interval
        }

        let amostras: [TimeInterval] = [0, 15, 30, 45, 60]
        let intervalos = amostras.map(intervalo)

        XCTAssertEqual(intervalos, [
            .milliseconds(500),
            .milliseconds(1125),
            .milliseconds(1750),
            .milliseconds(2375),
            .seconds(3),
        ])
        // Estritamente crescente — nenhum patamar repetido no meio do caminho.
        for (a, b) in zip(intervalos, intervalos.dropFirst()) {
            XCTAssertLessThan(a, b)
        }
    }

    /// Interpolação linear: na METADE do `idleThreshold` o intervalo tem que
    /// ser exatamente a média aritmética entre piso e teto. É o ponto que
    /// distingue "rampa linear de verdade" de uma curva geométrica disfarçada
    /// — ver o comentário de `PollPacer.interval` pra por que linear foi a
    /// escolha.
    func testNaMetadeDoLimiarOIntervaloEAMediaEntrePisoETeto() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 30)
        let esperado = (PollPacer.piso.seconds + PollPacer.teto.seconds) / 2
        XCTAssertEqual(pacer.interval.seconds, esperado, accuracy: 0.0001)
    }

    /// O pedido explícito dela: "não precisa ser 30 segundos, pode deixar um
    /// minuto". Aos 59s ainda não chegou no teto; aos 60s chegou — e não
    /// antes disso, como era com o limiar antigo de 30s.
    func testAtingeOTetoAos60sENaoAntes() {
        var quaseLa = PollPacer()
        quaseLa.record(changed: false, elapsed: 59)
        XCTAssertLessThan(quaseLa.interval, PollPacer.teto)

        var chegou = PollPacer()
        chegou.record(changed: false, elapsed: 60)
        XCTAssertEqual(chegou.interval, PollPacer.teto)
    }

    /// Passar do limiar não extrapola a rampa para além do teto — o `min(...,
    /// 1.0)` da fração tem que travar ali, senão uma tela esquecida ligada a
    /// noite toda faria o poll dormir cada vez mais.
    func testMuitoAlemDoLimiarContinuaNoTetoSemExtrapolar() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 3600) // uma hora parada
        XCTAssertEqual(pacer.interval, PollPacer.teto)
    }

    /// O outro lado do pedido: uma ÚNICA mudança de tela, não importa de que
    /// altura da rampa, derruba `quietFor` a zero e o intervalo volta ao piso
    /// na mesma leitura — uma tecla digitada não pode esperar a rampa descer
    /// devagar de volta.
    func testUnicaMudancaDeTelaDerrubaAoPisoNaHora() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 60)
        XCTAssertEqual(pacer.interval, PollPacer.teto)

        pacer.record(changed: true, elapsed: 0.5)
        XCTAssertEqual(pacer.interval, PollPacer.piso)
    }

    /// Defeito 3 corrigido: `record` aceita qualquer `elapsed` REAL (custo de
    /// rede variável + sono efetivamente dormido) e acumula por soma simples
    /// — nada aqui está preso aos antigos valores nominais fixos (1,5 s ou
    /// 3 s). Duas rodadas com elapsed irregular têm que somar exatamente.
    func testElapsedRealDeValorIrregularAcumulaPorSoma() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 0.83)  // ex.: só o custo da 1ª requisição
        pacer.record(changed: false, elapsed: 2.17)  // ex.: custo da 2ª + sono da rodada anterior
        XCTAssertEqual(pacer.quietFor, 3.0, accuracy: 0.0001)
    }
}

/// `SonoRestante` — a aritmética do defeito 1 (descontar o custo real da
/// requisição do sleep) extraída pra fora da `Task` do laço, onde nenhum
/// teste alcançava antes.
final class SonoRestanteTests: XCTestCase {

    /// O caso comum: a requisição custou menos que o alvo, então o sleep é
    /// só a diferença — é isto que faz o período efetivo deixar de ser
    /// "alvo + RTT" (o bug original) e passar a ser só "alvo".
    func testDescontaCustoDoAlvoQuandoCustoEMenor() {
        let duracao = SonoRestante.duracao(alvo: .milliseconds(1500), custo: .milliseconds(400),
                                            piso: PollPacer.piso)
        XCTAssertEqual(duracao, .milliseconds(1100))
    }

    /// Custo zero (requisição instantânea, hipotética): dorme o alvo cheio,
    /// sem desconto nenhum.
    func testCustoZeroDormeOAlvoCheio() {
        let duracao = SonoRestante.duracao(alvo: .seconds(3), custo: .zero, piso: PollPacer.piso)
        XCTAssertEqual(duracao, .seconds(3))
    }

    /// O caso do requisito 1: a requisição já custou MAIS que o alvo (rede
    /// lenta, hub ocupado). O sleep calculado tem que ser o piso — nunca
    /// zero, nunca negativo. Zero derrubaria a única folga que evita rajada
    /// de handshakes SSH costas com costas (ver `PollPacer.piso`).
    func testCustoMaiorQueOAlvoCaiNoPisoENaoFicaNegativo() {
        let duracao = SonoRestante.duracao(alvo: .milliseconds(500), custo: .milliseconds(800),
                                            piso: PollPacer.piso)
        XCTAssertEqual(duracao, PollPacer.piso)
        XCTAssertGreaterThanOrEqual(duracao.seconds, 0)
    }

    /// Caso extremo do mesmo requisito: uma requisição que trava por muito
    /// mais tempo que o PRÓPRIO limiar de ociosidade (ex.: timeout de rede
    /// perto de um minuto). Mesmo aqui o resultado é só o piso — nunca um
    /// número negativo absurdo passado pro `Task.sleep`.
    func testCustoMuitoMaiorQueOLimiarDeOciosidadeAindaCaiNoPiso() {
        let duracao = SonoRestante.duracao(alvo: PollPacer.teto, custo: .seconds(70),
                                            piso: PollPacer.piso)
        XCTAssertEqual(duracao, PollPacer.piso)
    }
}

/// `DecorridoReal` — substituiu a variável `sonoAnterior` (o sono PLANEJADO)
/// por um instante de relógio real (`ultimoRegistro`). O que se prova aqui é
/// exatamente o motivo da troca: uma suspensão do app faz o `Task.sleep`
/// estourar muito além do planejado, e o `elapsed` alimentado ao pacer tem
/// que refletir o tempo REAL de parede, não o que tinha sido decidido dormir.
final class DecorridoRealTests: XCTestCase {

    /// Primeira volta do laço: não há `ultimoRegistro` (nil) — sem "desde
    /// quando" medir, o decorrido é só o custo desta própria requisição.
    func testPrimeiraVoltaSemRegistroAnteriorUsaOCusto() {
        let relogio = ContinuousClock()
        let agora = relogio.now
        let decorrido = DecorridoReal.desde(ultimoRegistro: nil, agora: agora, custo: .milliseconds(730))
        XCTAssertEqual(decorrido, .milliseconds(730))
    }

    /// Voltas seguintes: o decorrido é a DIFERENÇA REAL entre dois instantes
    /// de relógio — não o `custo` desta rodada nem qualquer valor planejado.
    /// `custo` aqui é deliberadamente diferente do intervalo real para provar
    /// que ele não entra nesta conta quando existe `ultimoRegistro`.
    func testVoltaSeguinteUsaOIntervaloRealEntreDoisInstantesNaoOCusto() {
        let relogio = ContinuousClock()
        let t0 = relogio.now
        let t1 = t0.advanced(by: .milliseconds(1240))
        let decorrido = DecorridoReal.desde(ultimoRegistro: t0, agora: t1, custo: .milliseconds(999))
        XCTAssertEqual(decorrido, .milliseconds(1240))
    }

    /// O caso que motivou a mudança: o app suspende (troca de app, tela
    /// bloqueada) e o `Task.sleep` planejado — digamos 500 ms, o piso — na
    /// prática estoura para 90 s de parede. Com a variável antiga
    /// (`sonoAnterior`, o sono PLANEJADO), o `elapsed` alimentado ao pacer
    /// continuaria sendo os 500 ms decididos, não os 90 s reais, e a rampa
    /// demoraria a subir mesmo com a tela parada havia muito mais que isso.
    /// Com `DecorridoReal`, o `elapsed` é o real: o `quietFor` acumula os 90 s
    /// de uma vez só e o pacer já lê o TETO na mesma rodada seguinte.
    func testSuspensaoLongaFazQuietForAcumularOTempoRealEARampaChegarAoTeto() {
        let relogio = ContinuousClock()
        let t0 = relogio.now
        let t1 = t0.advanced(by: .seconds(90)) // sono planejado era 500ms; suspensão estourou pra 90s

        let decorrido = DecorridoReal.desde(ultimoRegistro: t0, agora: t1, custo: .milliseconds(200))
        XCTAssertEqual(decorrido, .seconds(90))

        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: decorrido.seconds)
        XCTAssertEqual(pacer.interval, PollPacer.teto)
    }

    /// O oposto, e o outro caso que a mudança não pode quebrar: tela em
    /// movimento contínuo, uma requisição colada na outra sem folga de sono
    /// nenhuma — o intervalo REAL entre dois registros é só o custo da
    /// requisição (bem abaixo do piso), e como a tela mudou de novo o pacer
    /// continua no piso, não sobe.
    func testTelaEmMovimentoContinuoMantemOIntervaloNoPiso() {
        let relogio = ContinuousClock()
        let t0 = relogio.now
        let t1 = t0.advanced(by: .milliseconds(180)) // só o custo da requisição, sem sono de fato

        let decorrido = DecorridoReal.desde(ultimoRegistro: t0, agora: t1, custo: .milliseconds(180))
        XCTAssertEqual(decorrido, .milliseconds(180))

        var pacer = PollPacer()
        pacer.record(changed: true, elapsed: decorrido.seconds) // tela mudou de novo nesta rodada
        XCTAssertEqual(pacer.interval, PollPacer.piso)
    }
}

final class DurationSecondsTests: XCTestCase {

    /// `PollPacer.record` recebe `elapsed: TimeInterval`; o `start()` só tem a
    /// `Duration` do intervalo que acabou de dormir — esta conversão fecha a ponta.
    func testConverteDurationEmSegundos() {
        XCTAssertEqual(Duration.seconds(3).seconds, 3.0, accuracy: 0.0001)
    }

    func testConverteMilissegundosFracionarios() {
        XCTAssertEqual(Duration.milliseconds(1500).seconds, 1.5, accuracy: 0.0001)
    }

    func testZeroPermanceZero() {
        XCTAssertEqual(Duration.zero.seconds, 0, accuracy: 0.0001)
    }
}
