import SwiftUI

/// "Enter envia" nos compositores do app (chat da sessão e input do terminal).
///
/// Parece que bastaria um `.onSubmit`, e não basta: os dois campos são
/// `TextField(axis: .vertical)`, ou seja MULTILINHA — nesse modo o Return insere
/// uma quebra de linha no texto e **nunca** dispara `onSubmit`. Foi o bug de
/// 13/08/2026 ("o enter no ipad nao ta funcionando para enviar mensagem, tenho
/// que clicar na setinha"): a única forma de enviar era o botão.
///
/// E os dois teclados chegam por caminhos DIFERENTES:
///   - teclado **físico** (Magic Keyboard do iPad) passa por `.onKeyPress`;
///   - teclado **de tela** NÃO passa — `.onKeyPress` só existe para teclado
///     físico. O Return dele aparece apenas como um `\n` a mais no binding.
///
/// Por isso o sinal usado aqui é o `\n` que acabou de entrar no texto, que é o
/// que os DOIS teclados produzem — em vez de escutar a tecla, que só um deles
/// entrega. O `.onKeyPress` continua tendo um papel, mas só um: avisar
/// antecipadamente que a quebra é ⇧⏎ (intencional) e não deve virar envio.
enum ComposerEnter {
    /// O que o compositor faz com a mudança de texto.
    enum Acao: Equatable {
        /// Digitação normal, quebra intencional ou colagem: o texto novo fica como está.
        case nada
        /// A quebra recém-inserida era "enviar": manda este texto (o de ANTES da
        /// quebra, que é exatamente o texto sem ela) e limpa o campo.
        case enviar(String)
        /// Enter num campo só com espaço em branco: não há o que enviar, então só
        /// tira a quebra — sem isso o campo "vazio" ficaria com uma linha em branco
        /// dentro e o botão continuaria desabilitado, sem explicação visível.
        case limpar
    }

    /// - Parameters:
    ///   - anterior: texto antes da mudança.
    ///   - novo: texto depois da mudança.
    ///   - quebraIntencional: o `.onKeyPress` já viu um ⇧⏎ e esta é a quebra dele.
    static func acao(anterior: String, novo: String, quebraIntencional: Bool) -> Acao {
        // Sem quebra nenhuma no texto novo não há nada a decidir — é digitação.
        guard novo.contains("\n") else { return .nada }
        // ⇧⏎: quebra pedida de propósito, fica no texto.
        guard !quebraIntencional else { return .nada }
        // Só UMA quebra recém-inserida conta como Enter. Isso é o que separa o
        // Return de uma COLAGEM multilinha: colar um texto com quebras insere
        // vários caracteres de uma vez e não pode virar envio automático — enviaria
        // sozinho o que ela colou pra revisar antes.
        guard quebraFoiInserida(Array(anterior), Array(novo)) else { return .nada }
        // O envio manda `anterior` cru, e não `novo` sem a quebra, porque a quebra
        // pode ter entrado no MEIO do texto (cursor movido): tirar "a\nb" para
        // "ab" grudaria palavras. `anterior` é o texto exatamente como estava.
        if anterior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .limpar
        }
        return .enviar(anterior)
    }

    /// A tecla é o ⇧⏎ que insere quebra em vez de enviar? Só o teclado físico
    /// chega aqui — o de tela do iPad não tem ⇧⏎ e por isso não tem como pedir
    /// quebra; nele Return sempre envia, que é o comportamento de mensageiro que
    /// ela espera.
    static func ehQuebraIntencional(key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        key == .return && modifiers.contains(.shift)
    }

    /// Verdadeiro quando `novo` é `anterior` com UM `\n` inserido em alguma
    /// posição. Compara pelo prefixo comum para funcionar também com o cursor no
    /// meio do texto e com rascunho que já tinha quebras.
    private static func quebraFoiInserida(_ anterior: [Character], _ novo: [Character]) -> Bool {
        guard novo.count == anterior.count + 1 else { return false }
        var i = 0
        while i < anterior.count && anterior[i] == novo[i] { i += 1 }
        guard novo[i] == "\n" else { return false }
        return Array(novo[(i + 1)...]) == Array(anterior[i...])
    }
}
