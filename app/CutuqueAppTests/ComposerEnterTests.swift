import SwiftUI
import XCTest
@testable import CutuqueApp

/// Enter envia — o bug de 13/08/2026 era ter que clicar na setinha. Ver
/// ComposerEnter.swift para por que o sinal é o `\n` no texto e não a tecla.
final class ComposerEnterTests: XCTestCase {

    // MARK: O caso da reclamação

    func testEnterNoFimDoTextoEnvia() {
        // É isto que o teclado DE TELA do iPad produz: um `\n` no fim. Não passa
        // por onKeyPress nenhum, então este é o único caminho que o alcança.
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "oi", novo: "oi\n", quebraIntencional: false),
            .enviar("oi")
        )
    }

    func testTextoEnviadoNaoLevaAQuebra() {
        // A quebra é o gatilho, não conteúdo: não pode ir junto pro agente nem
        // pro tmux (no terminal ela viraria uma linha em branco enviada).
        guard case .enviar(let texto) = ComposerEnter.acao(
            anterior: "rode os testes", novo: "rode os testes\n", quebraIntencional: false
        ) else { return XCTFail("queria .enviar") }
        XCTAssertFalse(texto.contains("\n"))
    }

    // MARK: ⇧⏎ = quebra de linha, não envio

    func testShiftEnterNaoEnvia() {
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "linha 1", novo: "linha 1\n", quebraIntencional: true),
            .nada
        )
    }

    func testShiftEnterEhReconhecidoSoComShift() {
        XCTAssertTrue(ComposerEnter.ehQuebraIntencional(key: .return, modifiers: [.shift]))
        XCTAssertFalse(ComposerEnter.ehQuebraIntencional(key: .return, modifiers: []))
        // ⌘⏎ já era o atalho de enviar do terminal: não é pedido de quebra.
        XCTAssertFalse(ComposerEnter.ehQuebraIntencional(key: .return, modifiers: [.command]))
        XCTAssertFalse(ComposerEnter.ehQuebraIntencional(key: "a", modifiers: [.shift]))
    }

    // MARK: Digitação normal não pode disparar nada

    func testDigitarLetraNaoEnvia() {
        XCTAssertEqual(ComposerEnter.acao(anterior: "o", novo: "oi", quebraIntencional: false), .nada)
        XCTAssertEqual(ComposerEnter.acao(anterior: "", novo: "o", quebraIntencional: false), .nada)
    }

    func testApagarNaoEnvia() {
        // Apagar caractere de um rascunho que JÁ tem quebra (feita com ⇧⏎) não
        // pode virar envio só porque o texto contém `\n`.
        XCTAssertEqual(ComposerEnter.acao(anterior: "a\nbc", novo: "a\nb", quebraIntencional: false), .nada)
    }

    func testDigitarDepoisDeUmaQuebraIntencionalNaoEnvia() {
        XCTAssertEqual(ComposerEnter.acao(anterior: "a\n", novo: "a\nb", quebraIntencional: false), .nada)
    }

    // MARK: Colagem multilinha

    func testColarTextoComQuebrasNaoEnvia() {
        // Colar log/erro pra pedir análise é rotina. Enviar sozinho o que ela
        // colou pra revisar antes seria irreversível — vai pro agente na hora.
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "", novo: "erro:\nlinha 2\nlinha 3", quebraIntencional: false),
            .nada
        )
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "veja: ", novo: "veja: erro\nna linha 2\n", quebraIntencional: false),
            .nada
        )
    }

    // MARK: Campo em branco

    func testEnterNoCampoVazioSoTiraAQuebra() {
        // Sem isto o campo "vazio" ficaria com uma linha em branco dentro, o botão
        // seguiria desabilitado e nada explicaria o porquê.
        XCTAssertEqual(ComposerEnter.acao(anterior: "", novo: "\n", quebraIntencional: false), .limpar)
        XCTAssertEqual(ComposerEnter.acao(anterior: "   ", novo: "   \n", quebraIntencional: false), .limpar)
    }

    // MARK: Cursor no meio do texto

    func testEnterComCursorNoMeioEnviaOTextoInteiro() {
        // Cursor entre "abc" e "def" → o texto que ela quis mandar é "abcdef"
        // inteiro. Tirar a quebra de "abc\ndef" grudaria as palavras; por isso o
        // envio usa o texto de ANTES da quebra, não o de depois sem ela.
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "abcdef", novo: "abc\ndef", quebraIntencional: false),
            .enviar("abcdef")
        )
    }

    func testEnterNoFimDeRascunhoDeVariasLinhasEnvia() {
        // Rascunho montado com ⇧⏎ e enviado no fim: as quebras dele são conteúdo
        // e vão junto; só a última (a que disparou) é que sai.
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "linha 1\nlinha 2", novo: "linha 1\nlinha 2\n", quebraIntencional: false),
            .enviar("linha 1\nlinha 2")
        )
    }

    // MARK: Acentuação e emoji (o teclado dela é pt-BR)

    func testAcentoEEmojiNaoAtrapalhamAContagem() {
        // Contar em Character (grapheme cluster) e não em UTF-16 importa: "ção" e
        // emoji com modificador contariam errado e o Enter deixaria de funcionar
        // justo depois de palavra acentuada.
        XCTAssertEqual(
            ComposerEnter.acao(anterior: "manutenção 👩🏽‍💻", novo: "manutenção 👩🏽‍💻\n", quebraIntencional: false),
            .enviar("manutenção 👩🏽‍💻")
        )
    }

    // MARK: onSubmit — o caminho do teclado FÍSICO
    //
    // Bancada de 16/08: no Magic Keyboard o Return NÃO escreve `\n` — ele dispara
    // só o `onSubmit`, e o `onChange` (que `acao` atende) nunca roda. Sem estes
    // casos o Enter físico não envia nada, que era o bug das builds 21/22. Ela
    // confirmou: _"sim, é o teclado físico mesmo"_.

    func testSubmitEnviaOTextoDoCampo() {
        XCTAssertEqual(
            ComposerEnter.acaoSubmit(texto: "roda o deploy", quebraIntencional: false),
            .enviar
        )
    }

    func testSubmitComShiftEscreveAQuebraEmVezDeEnviar() {
        // A pegadinha que derrubaria um conserto ingênuo: `onSubmit` NÃO distingue
        // Shift — ⇧Return físico cai nele igual, e sem escrever `\n`. Se isto
        // virasse `.enviar`, ⇧⏎ deixaria de quebrar linha no teclado físico.
        XCTAssertEqual(
            ComposerEnter.acaoSubmit(texto: "primeira linha", quebraIntencional: true),
            .inserirQuebra
        )
    }

    func testSubmitEmCampoVazioNaoFazNada() {
        // Nem envia (não há o que enviar) nem abre linha em branco — isso só
        // deixaria o botão desabilitado sem explicação visível.
        XCTAssertEqual(ComposerEnter.acaoSubmit(texto: "", quebraIntencional: false), .nada)
        XCTAssertEqual(ComposerEnter.acaoSubmit(texto: "   \n  ", quebraIntencional: false), .nada)
    }

    func testSubmitComShiftEmCampoVazioTambemNaoAbreLinha() {
        XCTAssertEqual(ComposerEnter.acaoSubmit(texto: "  ", quebraIntencional: true), .nada)
    }

    func testSubmitEnviaRascunhoDeVariasLinhas() {
        // Rascunho montado com ⇧⏎: o Return final manda tudo, quebras inclusas.
        XCTAssertEqual(
            ComposerEnter.acaoSubmit(texto: "linha 1\nlinha 2", quebraIntencional: false),
            .enviar
        )
    }

    func testOsDoisCaminhosNaoSePisamNoMesmoToque() {
        // Cada teclado produz UM sinal só: o de tela escreve `\n` (e o `onSubmit`
        // não dispara); o físico dispara `onSubmit` (e não escreve nada, então não
        // há `onChange`). Aqui fica travada a consequência disso na lógica pura: o
        // texto que o físico entrega NÃO tem quebra recém-inserida, então `acao`
        // com ele devolve `.nada` — só o `acaoSubmit` envia. É o que impede envio
        // em dobro caso um dia os dois disparem no mesmo toque.
        let texto = "manda isso"
        XCTAssertEqual(
            ComposerEnter.acao(anterior: texto, novo: texto, quebraIntencional: false),
            .nada
        )
        XCTAssertEqual(ComposerEnter.acaoSubmit(texto: texto, quebraIntencional: false), .enviar)
    }
}
