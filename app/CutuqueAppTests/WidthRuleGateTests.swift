import XCTest
@testable import CutuqueApp

/// Cobre `WidthRuleGate.shouldApply` — a decisão pura extraída do
/// `RootSplitView` pro Critical "a regra dos 700 pt nunca reaplica ao trocar
/// de destino": trocar de destino/painel não muda `geo.size.width` por si
/// só, então o único jeito de reagir é reconsultar a última largura
/// CONHECIDA contra este mesmo guard. Todo valor esperado abaixo foi escrito
/// à mão — nenhum é derivado do próprio `shouldApply`.
final class WidthRuleGateTests: XCTestCase {

    /// Primeira entrada nesta chave (`appliedFor == nil`) com largura válida:
    /// aplica.
    func testSemChaveAplicadaAindaEComLarguraValidaAplica() {
        XCTAssertTrue(WidthRuleGate.shouldApply(appliedFor: nil, key: "sessions-chat", width: 500))
    }

    /// Mesma chave já aplicada antes: não reaplica — é o guard que impede
    /// aplicar duas vezes e sobrescrever a escolha manual da usuária no ⤡.
    func testMesmaChaveJaAplicadaNaoReaplica() {
        XCTAssertFalse(WidthRuleGate.shouldApply(appliedFor: "sessions-chat", key: "sessions-chat", width: 500))
    }

    /// Chave NOVA (trocou de destino ou de painel), mesmo com `appliedFor`
    /// não-nil de uma entrada anterior: aplica de novo — é o comportamento
    /// que faltava e que este ticket corrige (o Board sem essa reaplicação
    /// ficava preso em modo estreito sem saída).
    func testChaveNovaReaplicaMesmoComAppliedForDeOutraChave() {
        XCTAssertTrue(WidthRuleGate.shouldApply(appliedFor: "sessions-chat", key: "board-chat", width: 500))
    }

    /// Sem largura conhecida ainda (nenhuma medição chegou): não aplica —
    /// não há o que medir contra os 700 pt.
    func testSemLarguraConhecidaNaoAplica() {
        XCTAssertFalse(WidthRuleGate.shouldApply(appliedFor: nil, key: "board-chat", width: nil))
    }

    /// Largura zero (GeometryReader ainda não fez o primeiro layout): não
    /// aplica — mesma proteção que o código original tinha contra medições
    /// de largura ainda não assentadas.
    func testLarguraZeroNaoAplica() {
        XCTAssertFalse(WidthRuleGate.shouldApply(appliedFor: nil, key: "board-chat", width: 0))
    }

    /// Largura negativa (jamais deveria acontecer em produção, mas o guard
    /// de `width > 0` cobre defensivamente): não aplica.
    func testLarguraNegativaNaoAplica() {
        XCTAssertFalse(WidthRuleGate.shouldApply(appliedFor: nil, key: "board-chat", width: -10))
    }

    /// Chave nova mas ainda sem largura: continua sem aplicar — a troca de
    /// destino por si só não basta, precisa de uma largura conhecida pra
    /// medir contra a regra.
    func testChaveNovaSemLarguraNaoAplica() {
        XCTAssertFalse(WidthRuleGate.shouldApply(appliedFor: "sessions-chat", key: "board-chat", width: nil))
    }
}
