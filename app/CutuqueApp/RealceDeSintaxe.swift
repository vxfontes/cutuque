import SwiftUI

/// Realce de sintaxe para os arquivos de texto da máquina (12/08/2026 — pedido
/// da Vanessa: "os arquivos de texto será que tem como a gnt deixar com
/// corzinha? tipo md, .ts e tal").
///
/// **Estado: assinatura definitiva, corpo neutro.** Devolve o texto sem cor.
/// Isto é de propósito: a costura foi escrita antes das frentes paralelas para
/// que o visualizador de texto já compilasse chamando o nome final enquanto o
/// tokenizador era escrito em outra branch. Quem trocar o corpo **não muda esta
/// assinatura** — há chamador dependendo dela.
///
/// Contrato que o tokenizador tem de honrar:
///
/// 1. **Nunca perder caractere.** A concatenação das partes coloridas tem de ser
///    idêntica à entrada. Cor errada incomoda; texto sumido é defeito.
/// 2. **Um `AttributedString` só.** O resultado vai para um único `Text`. Quebrar
///    em um `Text` por linha — o jeito fácil de colorir — mataria a seleção de
///    texto exatamente como o `MarkdownText` matava no chat, que é o bug que a
///    leva anterior acabou de consertar.
/// 3. **Acima de `LimitesDeArquivo.tetoDeRealce` devolve sem cor**, sem varrer.
/// 4. **Função pura**, para caber em XCTest como o resto do projeto.
enum RealceDeSintaxe {
    static func aplicar(_ texto: String, linguagem: Linguagem?) -> AttributedString {
        AttributedString(texto)
    }
}
