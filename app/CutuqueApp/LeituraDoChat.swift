import SwiftUI

/// Quanto texto cabe na tela do chat, e quando a tela pode se mexer sozinha.
///
/// [31/08/2026] Os dois problemas vieram do mesmo pedido — "meu iphone consiga
/// visualizar bastante contexto, ler e entender melhor sem precisar pedir pra
/// resumir" — e têm a mesma natureza: o transcrito mostrava POUCO e ainda tirava
/// da mão de quem lê o controle de onde estava lendo.
///
/// Ficam juntos aqui, fora de qualquer View, porque são decisões testáveis: uma
/// é aritmética de tamanho, a outra é uma regra de "quando rolar". Nenhuma das
/// duas precisa de tela para ser conferida.

// MARK: - Escala de leitura

/// Ajuste de tamanho do texto do chat, em passos, **relativo ao tamanho que o
/// sistema já pede**.
///
/// A alternativa óbvia — gravar um `DynamicTypeSize` absoluto — foi descartada
/// de propósito: ela atropelaria a preferência de acessibilidade do aparelho.
/// Quem configurou o iPhone inteiro em texto grande continua recebendo texto
/// grande aqui; o que este ajuste faz é andar N passos a partir DALI. Por isso
/// o valor guardado é um deslocamento com sinal, e não um tamanho.
enum EscalaDeLeitura {
    /// Uma chave por classe de aparelho: no iPhone o ajuste normalmente é para
    /// baixo (caber mais contexto), no iPad para cima (ler à distância). Mesma
    /// separação que `TamanhoDeCodigo` e o tamanho do terminal já usam.
    static let chaveTelefone = "cutuque.leituraDoChat"
    static let chaveTablet = "cutuque.leituraDoChat.pad"

    /// Três passos para cada lado. Mais que isso não é ajuste, é outra tela:
    /// −3 a partir de `.large` chega em `.xSmall`, que é o menor que o sistema
    /// oferece, e +3 chega em `.xxxLarge`.
    static let minimo = -3
    static let maximo = 3

    static func dentroDaFaixa(_ passos: Int) -> Int {
        min(maximo, max(minimo, passos))
    }

    static func podeAumentar(_ passos: Int) -> Bool { passos < maximo }
    static func podeDiminuir(_ passos: Int) -> Bool { passos > minimo }

    /// Aplica o deslocamento sobre o tamanho que veio do ambiente.
    ///
    /// Anda pela lista de tamanhos do próprio SwiftUI (que inclui as faixas de
    /// acessibilidade no fim) e satura nas pontas: pedir "menor" no menor de
    /// todos devolve o menor de todos, sem estourar índice e sem virar outra
    /// coisa.
    static func aplicado(_ base: DynamicTypeSize, passos: Int) -> DynamicTypeSize {
        let tamanhos = DynamicTypeSize.allCases
        guard let atual = tamanhos.firstIndex(of: base) else { return base }
        let alvo = min(tamanhos.count - 1, max(0, atual + dentroDaFaixa(passos)))
        return tamanhos[alvo]
    }

    /// Rótulo curto para o menu — o número sozinho ("−2") não diz nada.
    static func rotulo(_ passos: Int) -> String {
        switch dentroDaFaixa(passos) {
        case ..<0: return "Compacto \(dentroDaFaixa(passos))"
        case 0: return "Tamanho do sistema"
        default: return "Ampliado +\(dentroDaFaixa(passos))"
        }
    }
}

// MARK: - Rolagem do transcrito

/// Quando o transcrito pode rolar sozinho até o fim.
///
/// Antes ele rolava a CADA item novo, incondicionalmente. Numa sessão parada
/// isso é invisível; numa sessão viva — que é quando se lê o chat — significa
/// que subir para reler o raciocínio do agente dura até o próximo chunk chegar,
/// e aí a tela pula de volta para baixo sozinha. Era a razão prática de "não dá
/// pra ler no celular, tenho que pedir pra resumir": não é que o texto não
/// coubesse, é que ele não parava quieto.
///
/// A regra é uma só: **o app só acompanha quem já estava no fim.** Quem subiu
/// fica onde está, e recebe um aviso de que chegou coisa nova.
enum RolagemDoTranscrito {
    /// Folga em pontos para "estar no fim" — o suficiente para um resto de
    /// linha, um quique de rolagem elástica ou meio pixel de arredondamento não
    /// contarem como "a usuária subiu".
    static let folga: CGFloat = 40

    /// `fimY` é a posição do fim do conteúdo no espaço de coordenadas da rolagem
    /// e `altura` é a altura visível. O fim está à vista quando cai dentro da
    /// janela (com a folga).
    static func estaNoFim(fimY: CGFloat, altura: CGFloat) -> Bool {
        fimY <= altura + folga
    }

    /// Rola sozinho só para quem estava no fim. Separado de `estaNoFim` porque
    /// são duas perguntas diferentes — "onde ela está" e "posso mexer" — e a
    /// segunda vai ganhar mais condições com o tempo.
    static func deveAcompanhar(estavaNoFim: Bool) -> Bool { estavaNoFim }

    /// Texto do aviso de conteúdo novo fora da vista. Acima de 99 o número
    /// exato deixa de informar e só atrapalha a bolinha.
    static func aviso(naoLidas: Int) -> String? {
        guard naoLidas > 0 else { return nil }
        return naoLidas > 99 ? "99+" : "\(naoLidas)"
    }
}
