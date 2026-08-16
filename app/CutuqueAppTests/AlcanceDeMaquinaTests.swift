import SwiftUI
import XCTest
@testable import CutuqueApp

/// Alcance na aba Máquinas: o fio de `GET /machines/reachability` e a decisão
/// da bolinha (`PontoDeAlcance`).
///
/// O que se testa aqui é o que já custou desenho:
/// 1. Alcance e confiança são eixos SEPARADOS. O hub de propósito não criou um
///    quarto estado para "host-key não confiável" — isso cai em `naoRespondeu`
///    como qualquer outra falha. Quem mistura os dois na tela mente sobre um
///    deles: uma bolinha vermelha numa máquina com cadastro pela metade diria
///    "está fora do ar" quando ela nem foi tentada.
/// 2. Ausência tem que ser distinguível de "checando". Máquina que o hub ainda
///    não reportou não pode ganhar uma bolinha cinza permanente, que mentiria
///    sobre haver sondagem em curso.
///
/// Não há teste de "devo sondar agora?": esta lista DESMONTA ao trocar de seção
/// (vive num `switch nav.destination`, não no `ZStack` de abas montadas da
/// decisão #19), então o ciclo de vida é `.task`/`.onDisappear` do próprio
/// SwiftUI. Um predicado inventado só para ter o que testar seria teatro —
/// testaria uma função pura que não corresponde a nada que exista.
final class AlcanceDeMaquinaTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder.cutuque.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Fio

    func testDecodificaOsTresEstados() throws {
        let linhas: [MachineReachability] = try decode("""
        [{"machine":"macmini","state":"pronto","checked_at":"2026-08-16T12:00:00Z"},
         {"machine":"vps","state":"nao_respondeu","checked_at":"2026-08-16T12:00:00Z"},
         {"machine":"novo","state":"checando"}]
        """)
        XCTAssertEqual(linhas.map(\.state), [.pronto, .naoRespondeu, .checando])
    }

    /// `nao_respondeu` é VALOR, não chave: `.convertFromSnakeCase` mexe só nas
    /// chaves, então o rawValue tem que casar literal com o underscore. Trocar
    /// para `naoRespondeu` no enum sem o `= "nao_respondeu"` passaria batido no
    /// compilador e só quebraria em runtime.
    func testValorComUnderscoreNaoEConvertidoPorSnakeCase() throws {
        let linha: MachineReachability = try decode("""
        {"machine":"vps","state":"nao_respondeu"}
        """)
        XCTAssertEqual(linha.state, .naoRespondeu)
        XCTAssertEqual(ReachState.naoRespondeu.rawValue, "nao_respondeu")
    }

    /// `checked_at` some do JSON enquanto o hub nunca sondou (o campo é ponteiro
    /// com `omitempty` lá). Sem `Date?` aqui a lista inteira falharia de
    /// decodificar justamente no caso mais comum: hub recém-subido.
    func testCheckedAtAusenteDecodificaComoNil() throws {
        let linha: MachineReachability = try decode("""
        {"machine":"novo","state":"checando"}
        """)
        XCTAssertNil(linha.checkedAt)
    }

    /// Hub mais novo que invente um quarto estado não pode derrubar a decodificação
    /// da lista inteira — "ainda não sei" é a degradação honesta.
    func testEstadoDesconhecidoCaiEmChecando() throws {
        let linha: MachineReachability = try decode("""
        {"machine":"vps","state":"parcialmente_no_ar"}
        """)
        XCTAssertEqual(linha.state, .checando)
    }

    // MARK: - Decisão da bolinha

    func testProntoEVerdeNaoRespondeuEVermelho() {
        XCTAssertEqual(PontoDeAlcance.para(.pronto, needsTrust: false)?.cor, .green)
        XCTAssertEqual(PontoDeAlcance.para(.naoRespondeu, needsTrust: false)?.cor, .red)
    }

    /// Cinza e não âmbar: âmbar é a cor de aviso do app (o escudo do
    /// `needsTrust`), e gastá-la aqui faria toda abertura da aba piscar
    /// "atenção" antes da primeira resposta chegar.
    func testChecandoENeutroENaoAviso() {
        let ponto = PontoDeAlcance.para(.checando, needsTrust: false)
        XCTAssertEqual(ponto?.cor, .secondary)
        XCTAssertNotEqual(ponto?.cor, .orange)
    }

    /// A regra 1 do cabeçalho. Vale para QUALQUER estado — inclusive
    /// `naoRespondeu`, que é onde a mentira seria convincente.
    func testCadastroPelaMetadeNaoGanhaBolinha() {
        for estado: ReachState? in [nil, .checando, .pronto, .naoRespondeu] {
            XCTAssertNil(
                PontoDeAlcance.para(estado, needsTrust: true),
                "needsTrust tem escudo, não bolinha (estado \(String(describing: estado)))"
            )
        }
    }

    /// A regra 2. Máquina cadastrada agora, que a sondagem ainda não alcançou,
    /// fica SEM bolinha — e não com uma cinza para sempre.
    func testAusenteDaRespostaNaoDesenhaNada() {
        XCTAssertNil(PontoDeAlcance.para(nil, needsTrust: false))
    }

    /// Os três estados têm que ser distinguíveis entre si por quem enxerga cor
    /// e por quem não enxerga: cores diferentes E rótulos diferentes.
    func testEstadosSaoDistinguiveisEntreSi() {
        let pontos = [ReachState.pronto, .naoRespondeu, .checando]
            .compactMap { PontoDeAlcance.para($0, needsTrust: false) }
        XCTAssertEqual(pontos.count, 3)
        XCTAssertEqual(Set(pontos.map(\.rotulo)).count, 3)
        XCTAssertEqual(Set(pontos.map { String(describing: $0.cor) }).count, 3)
    }

    /// A bolinha é a única portadora do alcance na linha: sem rótulo o VoiceOver
    /// não teria como anunciar nada.
    func testTodoPontoTemRotuloParaLeitorDeTela() {
        for estado: ReachState in [.pronto, .naoRespondeu, .checando] {
            let rotulo = PontoDeAlcance.para(estado, needsTrust: false)?.rotulo
            XCTAssertFalse(rotulo?.isEmpty ?? true, "estado \(estado) sem rótulo")
        }
    }
}
