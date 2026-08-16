import Foundation

/// Segura a rajada de `tmuxResize` que o iPad provoca. A largura da view muda
/// na rotação, no botão de expandir e — pior — a cada frame do arraste do
/// divisor do Split View: sem isto, dezenas de POSTs seguidos pro hub.
///
/// Duas garantias: só o último tamanho da janela vira chamada, e um tamanho
/// igual ao último efetivamente enviado não vira chamada nenhuma.
@MainActor
final class ResizeDebouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var lastSent: (cols: Int, rows: Int)?

    init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    func schedule(cols: Int, rows: Int, send: @escaping @MainActor (Int, Int) -> Void) {
        if let last = lastSent, last.cols == cols, last.rows == rows { return }
        pending?.cancel()
        // `[weak self]`: sem isto, `self` ficaria retido por forte dentro do
        // Task, que por sua vez é retido por `self.pending` — um ciclo
        // clássico (self → pending → closure → self). O dono (a view do
        // terminal) chama `cancel()` no teardown e isso já quebra o ciclo,
        // mas capturar fraco é a segunda trava: se algum caminho futuro
        // esquecer de chamar `cancel()`, o objeto ainda assim é liberado
        // quando o último dono externo soltar, e o resize atrasado nunca
        // dispara — em vez de vazar até o delay todo passar.
        pending = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.lastSent = (cols, rows)
            send(cols, rows)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Ritmo do polling do espelho. Uma captura de 220×60 é ~13 KB contra ~4 KB da
/// tela do iPhone: com a tela parada, dormir mais é bateria e rede economizada
/// à toa.
///
/// [16/08/2026] Reescrito depois do relato da Vanessa ("sempre dá 3 segundos
/// mesmo com a tela em movimento", card 33fcfae34fe2a744). Quatro defeitos
/// encontrados, somados, nenhum isolado no tier lento:
/// (1) em `TerminalMirrorModel.start()` o sleep era SOMADO ao custo da
///     requisição (RTT de Tailscale+SSH+`tmux capture-pane`), nunca
///     descontado dele — o tier "rápido" nunca chegava perto do valor
///     nominal na prática; correção mora em `SonoRestante` + `start()`.
/// (2) o intervalo era lido ANTES do `record` — a decisão de quanto dormir
///     usava o estado de ANTES de contabilizar a rodada que tinha acabado de
///     rodar, atrasando a reação em uma volta inteira do laço.
/// (3) o `elapsed` contabilizado era o valor NOMINAL do intervalo, não o
///     tempo real do ciclo — o relógio de ociosidade (`quietFor`) andava mais
///     devagar que o relógio de verdade.
/// (4) dois níveis fixos (1,5 s / 3 s), sem nada no meio — combinado com (1),
///     o espelho parecia ter uma velocidade só.
/// (2) e (3) são corrigidos em `TerminalMirrorModel.start()` (a ordem
/// record→interval e o `elapsed` real); (4) é a rampa contínua abaixo.
struct PollPacer {
    /// Intervalo mínimo, aplicado assim que a tela muda (`quietFor == 0`) — e
    /// também o piso ABSOLUTO usado por `SonoRestante.duracao`, mesmo quando
    /// a requisição custou mais que o alvo. [16/08/2026] Baixado de 1500 ms
    /// (o antigo "fast", que por causa do defeito 1 nunca era de fato
    /// atingido) para 500 ms — e não desce mais que isso porque, no caminho
    /// REMOTO de captura (`runSSHTmux`, `tmux.go:196`), cada requisição abre
    /// uma sessão `ssh` NOVA, sem multiplexação. Sem piso, uma sequência de
    /// requisições baratas (tela pequena, hub ocioso) viraria uma rajada de
    /// handshakes SSH quase costas com costas.
    ///
    /// [16/08/2026, corrigido no mesmo dia] Este comentário afirmava antes que
    /// o handshake "custa 0,34–0,41 s (medido)" e que 500 ms deixaria
    /// "~100-150 ms de folga sobre o pior handshake já medido". **Retirado por
    /// falta de procedência**: aquele número vem de um comentário do card
    /// `33fcfae34fe2a744` que não registrou nem o comando nem a saída, e uma
    /// outra tentativa de medir a mesma coisa no mesmo dia se provou inválida
    /// (cronometrou a falha de verificação de host key, não um handshake).
    /// **Não existe medida válida do custo por request** — obter uma exige
    /// rodar DO macmini. O piso continua justificado pela FORMA do problema
    /// (sessão SSH nova por poll), não por um número; se um dia a medida vier,
    /// ela pode mudar o valor de 500 ms. Ver a nota de memória "App — Espelho
    /// ao Vivo: Rampa do Pacer e Custo Real do Poll", seção "Fase 2".
    static let piso: Duration = .milliseconds(500)

    /// Intervalo quando a tela está parada há `idleThreshold` ou mais. O
    /// número "3 segundos" que ela achou razoável continua o mesmo — o
    /// problema nunca foi o valor, era a rampa em degrau somada ao RTT não
    /// descontado (defeitos 1 e 4 acima).
    static let teto: Duration = .seconds(3)

    /// [16/08/2026] Pedido explícito dela: "não precisa ser 30 segundos, pode
    /// deixar um minuto". Antes de completar isto a rampa ainda está subindo
    /// de `piso` a `teto`; só depois disso o poll fica parado em `teto`.
    static let idleThreshold: TimeInterval = 60

    private(set) var quietFor: TimeInterval = 0

    mutating func record(changed: Bool, elapsed: TimeInterval) {
        quietFor = changed ? 0 : quietFor + elapsed
    }

    /// Rampa CONTÍNUA entre `piso` e `teto` — substitui o degrau de dois
    /// níveis (defeito 4). Interpolação LINEAR em vez de geométrica com teto:
    /// (a) é a forma mais simples de testar por igualdade exata em pontos
    /// conhecidos — por exemplo, na metade do `idleThreshold` o intervalo é
    /// exatamente a média aritmética entre `piso` e `teto`, sem depender de
    /// tolerância de ponto flutuante de `pow`/`exp`; (b) sobe de modo
    /// previsível do início ao fim, sem o platô achatado no começo nem a
    /// guinada no fim que uma curva geométrica com poucos pontos de
    /// calibração tende a produzir. Uma mudança de tela zera `quietFor` e
    /// este cálculo devolve `piso` na mesma hora — não existe um "nível
    /// intermediário" que precise decair primeiro antes de chegar lá.
    var interval: Duration {
        let fracao = min(quietFor / Self.idleThreshold, 1.0)
        let segundos = Self.piso.seconds + (Self.teto.seconds - Self.piso.seconds) * fracao
        return .seconds(segundos)
    }
}

/// Quanto dormir depois de uma rodada de poll, descontando o que ela já
/// custou (defeito 1: antes o sleep era somado ao RTT da requisição, nunca
/// descontado dele). Função pura e FORA da `Task` do laço de propósito — é a
/// única forma de testar esta aritmética sem levantar rede nem `Task.sleep`
/// de verdade (mesmo padrão de `MachineTerminalLifecycle`/`PontoDeAlcance`:
/// a decisão sai da view/model e vira algo que um teste alcança direto).
enum SonoRestante {
    /// `alvo`: o intervalo que o `PollPacer` decidiu para este momento de
    /// ociosidade. `custo`: quanto a requisição (medida com `ContinuousClock`
    /// pelo chamador) acabou de consumir. `piso`: o mínimo que ainda vale a
    /// pena dormir — se a requisição já custou mais que o alvo (rede lenta,
    /// hub ocupado), dorme o piso, nunca zero: dormir zero derrubaria a única
    /// folga que evita rajada de handshakes SSH de volta e meia (ver
    /// `PollPacer.piso`). `max` também cobre com segurança o caso em que
    /// `custo` é maior que o `idleThreshold` inteiro — o resultado nunca fica
    /// negativo, só cai no piso.
    ///
    /// A subtração é feita em `Duration`, não em `TimeInterval`/`Double`:
    /// `Duration` guarda segundos+attosegundos como inteiros, então `alvo -
    /// custo` é EXATA — passar por `.seconds` (Double) e voltar reintroduz o
    /// arredondamento binário de frações como 0,4 (não representável exatamente
    /// em ponto flutuante) e um teste de igualdade estrita como
    /// `1500ms − 400ms == 1100ms` falha por diferença de última casa, mesmo os
    /// dois imprimindo "1.1 seconds". `Duration` também é assinado (permite
    /// negativo), então a subtração nunca trava mesmo com `custo > alvo`.
    static func duracao(alvo: Duration, custo: Duration, piso: Duration) -> Duration {
        max(alvo - custo, piso)
    }
}

extension Duration {
    /// A duração em segundos, para contas de tempo ocioso.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// [16/08/2026] Quanto tempo de PAREDE realmente passou desde o último
/// `record` do `PollPacer` — não quanto sono foi PLANEJADO.
///
/// Substituiu a variável `sonoAnterior` que o laço de `TerminalMirrorModel`
/// carregava entre voltas: ela guardava o valor que `SonoRestante.duracao`
/// tinha DECIDIDO dormir, não o que o `Task.sleep` de fato dormiu. Se o app
/// suspende (troca de app, tela bloqueada) o `Task.sleep` estoura MUITO além
/// do planejado — mas `sonoAnterior` continuava com o número pequeno de
/// antes, então `pacer.record` recebia um `elapsed` menor que o real e
/// `quietFor` demorava a subir: a rampa achava a tela "ainda ativa" bem
/// depois de ela estar parada havia bem mais que isso.
///
/// A correção é medir o relógio de verdade: cada rodada guarda o instante em
/// que terminou (`ultimoRegistro`), e a rodada seguinte usa a DIFERENÇA entre
/// os dois instantes como `elapsed` — isso inclui, de graça, qualquer
/// suspensão do app no meio do caminho, porque `ContinuousClock` não pára
/// enquanto o processo existe (ao contrário de um relógio de parede que
/// poderia voltar no tempo).
///
/// Função pura FORA da `Task` do laço, mesmo padrão de `SonoRestante`: a
/// mesma decisão (primeira volta vs. voltas seguintes) merece teste que não
/// dependa de rodar `Task.sleep` de verdade nem de simulador — dá pra simular
/// uma suspensão longa avançando o "agora" com `.advanced(by:)` num
/// `ContinuousClock.Instant`, sem esperar o tempo de verdade passar.
enum DecorridoReal {
    /// `ultimoRegistro`: instante do `record` anterior, ou `nil` na primeira
    /// volta do laço — aí não existe "desde quando" medir, e o decorrido é só
    /// o custo desta própria requisição. `agora`: instante em que esta rodada
    /// terminou de medir seu custo. `custo`: quanto a requisição desta rodada
    /// levou (o mesmo valor que já alimenta `SonoRestante`).
    static func desde(ultimoRegistro: ContinuousClock.Instant?, agora: ContinuousClock.Instant,
                       custo: Duration) -> Duration {
        guard let ultimoRegistro else { return custo }
        return agora - ultimoRegistro
    }
}
