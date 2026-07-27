import XCTest
@testable import CutuqueApp

/// Cobre `LayoutRuleGate.shouldApply` — o guard que faz a regra de layout
/// (orientação decide `columnVisibility`, ver `NavigationState.applyLayoutRule`)
/// rodar UMA vez por chave, pra que a usuária apertar o ⤡ (expandir/recolher
/// manual) não seja desfeito no frame seguinte, e reaplicar quando
/// destino/seleção/orientação mudam de fato. O tipo (e este arquivo) foi
/// renomeado de `WidthRuleGate`
/// (regra dos 700 pt): mesmo guard, chave nova (destino-orientação-seleção
/// no lugar de destino-painel). Todo valor esperado abaixo foi escrito à
/// mão — nenhum é derivado do próprio `shouldApply`.
final class LayoutRuleGateTests: XCTestCase {

    /// Primeira entrada nesta chave (`appliedFor == nil`): aplica.
    func testSemChaveAplicadaAindaAplica() {
        XCTAssertTrue(LayoutRuleGate.shouldApply(appliedFor: nil, key: "sessions-true-false"))
    }

    /// Mesma chave já aplicada antes: não reaplica — é o guard que impede
    /// aplicar duas vezes e sobrescrever a escolha manual da usuária no ⤡.
    func testMesmaChaveJaAplicadaNaoReaplica() {
        XCTAssertFalse(LayoutRuleGate.shouldApply(appliedFor: "sessions-true-false", key: "sessions-true-false"))
    }

    /// Chave nova por troca de DESTINO (mesmo com `appliedFor` de uma entrada
    /// anterior): aplica de novo — é o comportamento que o Critical original
    /// corrigiu (o Board sem essa reaplicação ficava preso em modo estreito
    /// sem saída).
    func testChaveNovaPorDestinoReaplicaMesmoComAppliedForDeOutraChave() {
        XCTAssertTrue(LayoutRuleGate.shouldApply(appliedFor: "sessions-true-false", key: "board-true-false"))
    }

    /// Chave nova por troca de ORIENTAÇÃO (mesmo destino, mesma seleção):
    /// aplica de novo — é o eixo que esta tarefa introduz. Sem isto, girar o
    /// iPad com uma sessão escolhida nunca recolocaria o painel em tela
    /// cheia (retrato) nem devolveria as três colunas (paisagem).
    func testChaveNovaPorOrientacaoReaplica() {
        XCTAssertTrue(LayoutRuleGate.shouldApply(appliedFor: "sessions-true-true", key: "sessions-false-true"))
    }

    /// Chave nova por troca de SELEÇÃO (mesmo destino, mesma orientação):
    /// aplica de novo — escolher/desescolher uma sessão em retrato precisa
    /// recalcular o colapso.
    func testChaveNovaPorSelecaoReaplica() {
        XCTAssertTrue(LayoutRuleGate.shouldApply(appliedFor: "sessions-true-false", key: "sessions-true-true"))
    }
}
