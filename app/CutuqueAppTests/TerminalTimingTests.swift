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
}

final class PollPacerTests: XCTestCase {

    func testComecaRapido() {
        XCTAssertEqual(PollPacer().interval, .milliseconds(1500))
    }

    func testDesaceleraDepoisDe30sSemMudanca() {
        var pacer = PollPacer()
        for _ in 0..<19 { pacer.record(changed: false, elapsed: 1.5) }  // 28,5 s
        XCTAssertEqual(pacer.interval, .milliseconds(1500))
        pacer.record(changed: false, elapsed: 1.5)                       // 30,0 s
        XCTAssertEqual(pacer.interval, .seconds(3))
    }

    func testPrimeiroDiffVoltaAoRitmoRapido() {
        var pacer = PollPacer()
        pacer.record(changed: false, elapsed: 60)
        XCTAssertEqual(pacer.interval, .seconds(3))
        pacer.record(changed: true, elapsed: 3)
        XCTAssertEqual(pacer.interval, .milliseconds(1500))
    }
}
