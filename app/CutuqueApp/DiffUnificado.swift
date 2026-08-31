import Foundation

/// Parser de *unified diff* (a saída de `git diff`) para a estrutura que a tela
/// precisa: arquivos → hunks → linhas numeradas.
///
/// ## Por que parsear em vez de mostrar o texto cru
///
/// Até 31/08/2026 o `GitDiffView` jogava o diff inteiro dentro de um `Text` com
/// as cores ANSI que o `git` já mandava. Funciona para *ver* que existe
/// alteração; não serve para o que ela pediu ("o ipad consiga substituir ter
/// que voltar pro pc pra visualizar melhor um trecho de codigo"). Sem estrutura
/// não dá para: pular para um arquivo, saber em que linha do arquivo real uma
/// mudança caiu, contar +/− por arquivo, buscar dentro do diff, ou desenhar só
/// o pedaço que está à vista. Tudo isso sai de graça depois que o texto vira
/// dado.
///
/// ## Contrato
///
/// 1. **Função pura**, sem SwiftUI — roda em XCTest como o resto da lógica do
///    projeto (`AbasNavegacao`, `ComposerEnter`, `RoteadorDeTexto`…).
/// 2. **Nunca inventa nem perde linha de conteúdo.** Uma linha de hunk vira
///    exatamente uma `Linha`, com o marcador (`+`, `-`, espaço) retirado do
///    texto e guardado no `tipo`.
/// 3. **Tolera diff cortado no meio** (`GitDiff.truncated`): o último hunk pode
///    acabar antes da conta do cabeçalho fechar, e isso não é erro.
/// 4. **Tolera ANSI.** O hub novo manda o diff sem cor, mas um hub antigo manda
///    com — e um app novo falando com hub antigo é o caso normal enquanto a
///    build não subiu nas duas pontas. A limpeza só acontece se houver ESC no
///    texto, então o caminho comum não paga nada por ela.
enum DiffUnificado {
    enum TipoDeLinha: Equatable, Sendable {
        /// Linha inalterada, presente nos dois lados.
        case contexto
        case adicao
        case remocao
        /// `\ No newline at end of file` e afins: não conta linha em lado nenhum.
        case meta
    }

    struct Linha: Identifiable, Equatable, Sendable {
        /// Índice global dentro do diff inteiro — estável para `ForEach` e
        /// suficiente para ancorar rolagem.
        let id: Int
        let tipo: TipoDeLinha
        /// Número da linha no arquivo ANTES da mudança (nil em adição/meta).
        let antiga: Int?
        /// Número da linha no arquivo DEPOIS da mudança (nil em remoção/meta).
        let nova: Int?
        /// Conteúdo SEM o marcador de coluna 1.
        let texto: String
    }

    struct Hunk: Identifiable, Equatable, Sendable {
        let id: Int
        /// O `@@ -1,4 +1,6 @@ contexto` inteiro, como o git escreveu.
        let cabecalho: String
        /// A parte depois do segundo `@@` — normalmente a assinatura da função
        /// onde a mudança caiu. Vazia quando o git não achou nenhuma.
        let contexto: String
        let linhas: [Linha]
    }

    struct Arquivo: Identifiable, Equatable, Sendable {
        let id: Int
        /// Caminho relativo à raiz do repositório, já sem o `a/`/`b/`.
        let caminho: String
        /// Preenchido só em rename/copy — o nome de onde o arquivo veio.
        let caminhoAntigo: String?
        let hunks: [Hunk]
        let adicoes: Int
        let remocoes: Int
        /// `Binary files … differ`: não há linha para mostrar.
        let binario: Bool
        /// Comprimento da linha mais longa do arquivo (cabeçalhos de hunk
        /// incluídos). Sai do parse porque a tela precisa dele a cada desenho
        /// quando a quebra de linha está desligada — para o fundo colorido de
        /// cada linha ir até o fim da mais larga — e varrer o arquivo inteiro
        /// por tecla digitada na busca não é aceitável num diff de megabytes.
        let maiorColuna: Int

        var nomeCurto: String {
            caminho.split(separator: "/").last.map(String.init) ?? caminho
        }

        var pasta: String {
            let partes = caminho.split(separator: "/")
            guard partes.count > 1 else { return "" }
            return partes.dropLast().joined(separator: "/")
        }

        /// Extensão em minúsculas, para o realce de sintaxe escolher a regra.
        var linguagem: Linguagem? {
            TipoDeArquivo.de(nome: caminho).linguagemDoFonte
        }
    }

    // MARK: - Entrada

    static func parse(_ texto: String) -> [Arquivo] {
        // Um hub antigo ainda manda `color.ui=always`. Só paga a limpeza quem
        // realmente recebeu ANSI.
        let limpo = texto.contains("\u{1B}") ? Ansi.plain(texto) : texto
        guard !limpo.isEmpty else { return [] }
        var parser = Estado()
        // `omittingEmptySubsequences: false` porque uma linha vazia no diff é
        // uma linha de contexto vazia de verdade — descartá-la desalinharia a
        // numeração de tudo que vem depois.
        for linha in limpo.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consumir(String(linha))
        }
        return parser.finalizar()
    }

    // MARK: - Máquina de estados

    /// O parser guarda estado porque um diff é um formato de linhas, não de
    /// blocos delimitados: só dá para saber que um arquivo acabou quando o
    /// próximo `diff --git` aparece (ou o texto termina).
    private struct Estado {
        private var arquivos: [Arquivo] = []
        private var idDeLinha = 0
        private var idDeHunk = 0

        // Arquivo em construção
        private var abriu = false
        private var caminho = ""
        private var caminhoAntigo: String?
        private var caminhoDoCabecalho = ""
        private var binario = false
        private var hunks: [Hunk] = []
        private var adicoes = 0
        private var remocoes = 0
        private var maiorColuna = 0

        // Hunk em construção
        private var emHunk = false
        private var cabecalhoDoHunk = ""
        private var contextoDoHunk = ""
        private var linhas: [Linha] = []
        private var proximaAntiga = 0
        private var proximaNova = 0
        /// Quantas linhas ainda faltam de cada lado, segundo o cabeçalho. É o
        /// que decide onde o hunk termina — e não "a linha começa com espaço/+/-".
        /// Sem isso, um `--- a/x` de um arquivo seguinte seria lido como remoção
        /// da linha `-- a/x`, e a partir dali o diff inteiro sai torto.
        private var faltamAntigas = 0
        private var faltamNovas = 0

        mutating func consumir(_ linha: String) {
            // A quota do cabeçalho diz onde o hunk acaba — menos para a nota
            // `\ No newline at end of file`, que o git escreve DEPOIS da última
            // linha contada. Com os dois contadores já zerados ela cairia fora
            // do hunk e sumiria: nenhum prefixo de cabeçalho bate em `\`. Dentro
            // de um hunk nada mais começa com `\` (conteúdo vem sempre com
            // marcador ` `, `+` ou `-`), então deixá-la entrar é seguro.
            if emHunk, faltamAntigas > 0 || faltamNovas > 0 || linha.hasPrefix("\\") {
                if consumirLinhaDeHunk(linha) { return }
            }
            if linha.hasPrefix("diff --git ") {
                fecharArquivo()
                abrirArquivo(linha)
                return
            }
            guard abriu else { return } // preâmbulo antes do primeiro arquivo
            if linha.hasPrefix("@@") {
                abrirHunk(linha)
                return
            }
            fecharHunk()
            aplicarCabecalho(linha)
        }

        mutating func finalizar() -> [Arquivo] {
            fecharArquivo()
            return arquivos
        }

        // MARK: Arquivo

        private mutating func abrirArquivo(_ linha: String) {
            abriu = true
            caminhoDoCabecalho = DiffUnificado.caminhoDoDiffGit(linha)
            caminho = caminhoDoCabecalho
            caminhoAntigo = nil
            binario = false
            hunks = []
            adicoes = 0
            remocoes = 0
            maiorColuna = 0
        }

        private mutating func fecharArquivo() {
            fecharHunk()
            guard abriu else { return }
            arquivos.append(Arquivo(id: arquivos.count,
                                    caminho: caminho.isEmpty ? "(sem nome)" : caminho,
                                    caminhoAntigo: caminhoAntigo,
                                    hunks: hunks,
                                    adicoes: adicoes,
                                    remocoes: remocoes,
                                    binario: binario,
                                    maiorColuna: maiorColuna))
            abriu = false
            hunks = []
        }

        /// Linhas de cabeçalho entre o `diff --git` e o primeiro `@@`.
        private mutating func aplicarCabecalho(_ linha: String) {
            if linha.hasPrefix("Binary files ") || linha.hasPrefix("GIT binary patch") {
                binario = true
            } else if linha.hasPrefix("rename from ") {
                caminhoAntigo = String(linha.dropFirst("rename from ".count))
            } else if linha.hasPrefix("copy from ") {
                caminhoAntigo = String(linha.dropFirst("copy from ".count))
            } else if linha.hasPrefix("rename to ") {
                // Renomear sem tocar no conteúdo (`git mv` e mais nada) produz
                // um diff SEM `---`/`+++` e sem hunk: só `similarity index
                // 100%`, `rename from` e `rename to`. Sem ler esta linha, o
                // único nome disponível vira o lado esquerdo do `diff --git`,
                // e a tela mostra "old.txt ← old.txt" — o nome novo, que é a
                // única coisa que aconteceu, não aparece em lugar nenhum.
                caminho = String(linha.dropFirst("rename to ".count))
            } else if linha.hasPrefix("copy to ") {
                caminho = String(linha.dropFirst("copy to ".count))
            } else if linha.hasPrefix("+++ ") {
                // `+++ b/x` manda no nome, exceto quando o arquivo foi apagado
                // (`+++ /dev/null`) — aí o nome bom é o do `--- a/x`.
                if let nome = DiffUnificado.caminhoDeMarcador(linha) { caminho = nome }
            } else if linha.hasPrefix("--- ") {
                if let nome = DiffUnificado.caminhoDeMarcador(linha), caminho.isEmpty || caminho == caminhoDoCabecalho {
                    caminho = nome
                }
            }
        }

        // MARK: Hunk

        private mutating func abrirHunk(_ linha: String) {
            fecharHunk()
            let cabecalho = DiffUnificado.lerCabecalho(linha)
            emHunk = true
            cabecalhoDoHunk = linha
            maiorColuna = max(maiorColuna, linha.count)
            contextoDoHunk = cabecalho.contexto
            linhas = []
            proximaAntiga = cabecalho.antigaInicio
            proximaNova = cabecalho.novaInicio
            faltamAntigas = cabecalho.antigaQtd
            faltamNovas = cabecalho.novaQtd
            idDeHunk += 1
        }

        private mutating func fecharHunk() {
            guard emHunk else { return }
            if !linhas.isEmpty || !cabecalhoDoHunk.isEmpty {
                hunks.append(Hunk(id: idDeHunk, cabecalho: cabecalhoDoHunk, contexto: contextoDoHunk, linhas: linhas))
            }
            emHunk = false
            linhas = []
            cabecalhoDoHunk = ""
            contextoDoHunk = ""
            faltamAntigas = 0
            faltamNovas = 0
        }

        /// Devolve `false` quando a linha não pertence ao hunk — aí quem chamou
        /// segue o fluxo normal (novo arquivo, novo hunk, cabeçalho).
        private mutating func consumirLinhaDeHunk(_ linha: String) -> Bool {
            let marcador = linha.first
            switch marcador {
            case "+":
                anexar(.adicao, texto: String(linha.dropFirst()))
                adicoes += 1
                faltamNovas -= 1
            case "-":
                anexar(.remocao, texto: String(linha.dropFirst()))
                remocoes += 1
                faltamAntigas -= 1
            case " ":
                anexar(.contexto, texto: String(linha.dropFirst()))
                faltamAntigas -= 1
                faltamNovas -= 1
            case "\\":
                // `\ No newline at end of file` — nota do git, não conteúdo.
                anexar(.meta, texto: linha)
            case nil:
                // Linha vazia SEM o espaço de marcador. O git escreve assim
                // quando a linha de contexto é vazia e alguma ferramenta no
                // caminho aparou espaços à direita; tratar como contexto é o
                // que mantém a numeração certa.
                anexar(.contexto, texto: "")
                faltamAntigas -= 1
                faltamNovas -= 1
            default:
                return false
            }
            return true
        }

        private mutating func anexar(_ tipo: TipoDeLinha, texto: String) {
            var antiga: Int?
            var nova: Int?
            switch tipo {
            case .contexto:
                antiga = proximaAntiga; nova = proximaNova
                proximaAntiga += 1; proximaNova += 1
            case .adicao:
                nova = proximaNova; proximaNova += 1
            case .remocao:
                antiga = proximaAntiga; proximaAntiga += 1
            case .meta:
                break
            }
            linhas.append(Linha(id: idDeLinha, tipo: tipo, antiga: antiga, nova: nova, texto: texto))
            maiorColuna = max(maiorColuna, texto.count)
            idDeLinha += 1
        }
    }
}

// MARK: - Leitura de cabeçalhos

extension DiffUnificado {
    struct CabecalhoDeHunk: Equatable {
        var antigaInicio = 0
        var antigaQtd = 0
        var novaInicio = 0
        var novaQtd = 0
        var contexto = ""
    }

    /// `@@ -12,7 +12,9 @@ func exemplo()` → começos, quantidades e contexto.
    /// Quantidade ausente (`@@ -1 +1 @@`) significa 1, como manda o formato.
    static func lerCabecalho(_ linha: String) -> CabecalhoDeHunk {
        var out = CabecalhoDeHunk()
        guard let inicio = linha.range(of: "@@ "),
              let fim = linha.range(of: " @@", range: inicio.upperBound..<linha.endIndex)
        else { return out }
        let miolo = linha[inicio.upperBound..<fim.lowerBound]
        out.contexto = String(linha[fim.upperBound...]).trimmingCharacters(in: .whitespaces)
        for campo in miolo.split(separator: " ") {
            guard let sinal = campo.first, sinal == "-" || sinal == "+" else { continue }
            let numeros = campo.dropFirst().split(separator: ",")
            let inicioNum = Int(numeros.first ?? "0") ?? 0
            let qtd = numeros.count > 1 ? (Int(numeros[1]) ?? 0) : 1
            if sinal == "-" {
                out.antigaInicio = inicioNum; out.antigaQtd = qtd
            } else {
                out.novaInicio = inicioNum; out.novaQtd = qtd
            }
        }
        return out
    }

    /// `--- a/x/y.swift` / `+++ b/x/y.swift` → `x/y.swift`. `/dev/null` → nil.
    static func caminhoDeMarcador(_ linha: String) -> String? {
        let resto = String(linha.dropFirst(4))
        guard resto != "/dev/null" else { return nil }
        if resto.hasPrefix("a/") || resto.hasPrefix("b/") { return String(resto.dropFirst(2)) }
        return resto.isEmpty ? nil : resto
    }

    /// `diff --git a/x b/x` → `x`.
    ///
    /// Nome com espaço é ambíguo neste formato (o git só resolve com aspas, e
    /// nem sempre) — por isso a leitura aqui é uma pista, não a verdade: quem
    /// manda no nome final é o `+++ b/…`, que vem logo abaixo e não tem essa
    /// ambiguidade. Este valor só sobrevive em diff de mudança de modo, que não
    /// traz `---`/`+++`.
    static func caminhoDoDiffGit(_ linha: String) -> String {
        let resto = String(linha.dropFirst("diff --git ".count))
        if let corte = resto.range(of: " b/") {
            let esquerda = String(resto[resto.startIndex..<corte.lowerBound])
            return esquerda.hasPrefix("a/") ? String(esquerda.dropFirst(2)) : esquerda
        }
        return resto
    }
}

// MARK: - Resumo para a tela

extension Array where Element == DiffUnificado.Arquivo {
    var totalDeAdicoes: Int { reduce(0) { $0 + $1.adicoes } }
    var totalDeRemocoes: Int { reduce(0) { $0 + $1.remocoes } }
}
