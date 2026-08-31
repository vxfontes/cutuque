import Foundation

/// Busca por linha dentro de um texto já carregado — a mesma pergunta que o
/// ⌘F faz num editor: "em que linhas isto aparece, e como eu ando entre elas".
///
/// [31/08/2026] Nasceu para o visualizador de arquivos e para o diff, que
/// precisavam exatamente da mesma coisa: contar ocorrências, mostrar "3 de 12" e
/// pular para a próxima. É o pedaço que faz o iPad servir para ACHAR um trecho,
/// e não só para olhar um trecho — sem isso, encontrar uma função num arquivo de
/// 2 mil linhas continua sendo motivo para voltar ao computador.
///
/// Puro, sem SwiftUI: cabe em XCTest como o resto da lógica do projeto.
enum BuscaEmTexto {
    /// Índices (base 0) das linhas que contêm o termo, na ordem do arquivo.
    ///
    /// Comparação sem diferenciar maiúscula/minúscula e sem diferenciar acento
    /// (`localizedStandardContains`) — é o comportamento que a busca do sistema
    /// tem, e digitar "funcao" e não achar `função` seria a pior forma de
    /// descobrir que a busca é literal.
    static func linhasComOcorrencia(_ linhas: [String], termo: String) -> [Int] {
        let alvo = termo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alvo.isEmpty else { return [] }
        var achados: [Int] = []
        for (indice, linha) in linhas.enumerated() where linha.localizedStandardContains(alvo) {
            achados.append(indice)
        }
        return achados
    }

    /// Quantas VEZES o termo aparece, contando repetição na mesma linha. É outro
    /// número do que `linhasComOcorrencia.count`, e a diferença importa: um
    /// contador que diz "2" para um arquivo com 40 ocorrências em 2 linhas está
    /// mentindo sobre o tamanho do que ela vai encontrar.
    static func totalDeOcorrencias(_ linhas: [String], termo: String) -> Int {
        let alvo = termo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alvo.isEmpty else { return 0 }
        var total = 0
        for linha in linhas {
            var restante = Substring(linha)
            while let faixa = restante.range(of: alvo, options: [.caseInsensitive, .diacriticInsensitive]) {
                total += 1
                restante = restante[faixa.upperBound...]
                if restante.isEmpty { break }
            }
        }
        return total
    }

    /// Anda pela lista de achados dando a volta nas pontas.
    ///
    /// Circular de propósito: quem chega na última ocorrência e aperta "próxima"
    /// quer voltar à primeira, não encontrar um botão desligado — é assim que a
    /// busca de qualquer editor se comporta.
    static func proximo(_ atual: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (atual + 1) % total
    }

    static func anterior(_ atual: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (atual - 1 + total) % total
    }

    /// Aparo defensivo para quando a lista de achados encolhe debaixo do índice
    /// — acontece a cada tecla digitada na busca, e um índice velho maior que a
    /// lista nova estouraria o `achados[i]`.
    static func indiceSeguro(_ indice: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return min(max(0, indice), total - 1)
    }

    /// Rótulo "3 de 12" (ou "nenhuma"), pronto para a barra de busca.
    static func rotulo(indice: Int, achados: Int) -> String {
        guard achados > 0 else { return "nenhuma" }
        return "\(indiceSeguro(indice, total: achados) + 1) de \(achados)"
    }
}
