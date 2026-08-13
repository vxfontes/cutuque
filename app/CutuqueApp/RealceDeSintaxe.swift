import SwiftUI

/// Realce de sintaxe para os arquivos de texto da máquina (12/08/2026 — pedido
/// da Vanessa: "os arquivos de texto será que tem como a gnt deixar com
/// corzinha? tipo md, .ts e tal").
///
/// Contrato que este arquivo tem de honrar (é o que o teste cobra primeiro):
///
/// 1. **Nunca perder caractere.** A concatenação das partes coloridas tem de ser
///    idêntica à entrada. Cor errada incomoda; texto sumido é defeito. Por isso
///    todo o desenho abaixo trabalha por **fatias do texto original** — nunca
///    reescreve, insere ou remove um caractere, só decide a cor de cada fatia.
/// 2. **Um `AttributedString` só.** O resultado vai para um único `Text`. Quebrar
///    em um `Text` por linha — o jeito fácil de colorir — mataria a seleção de
///    texto exatamente como o `MarkdownText` matava no chat, que é o bug que a
///    leva anterior acabou de consertar.
/// 3. **Acima de `LimitesDeArquivo.tetoDeRealce` devolve sem cor**, sem varrer:
///    o teto é checado ANTES de qualquer laço, então um arquivo grande não custa
///    nem uma iteração.
/// 4. **Função pura**, para caber em XCTest como o resto do projeto.
///
/// ## Por que "linguagem como dado"
///
/// Cada linguagem entra como um `RegraDeLinguagem`: palavras-chave, marcador de
/// comentário de linha, par de comentário de bloco e aspas válidas. Acrescentar
/// uma linguagem nova é acrescentar uma entrada na tabela `regras` — nunca um
/// novo `case` no tokenizador. O tokenizador em si (`tokenizar`) é o MESMO texto
/// de código para as 18 linguagens; só o dado muda.
///
/// ## Por que uma passada só (nada de regex em laço)
///
/// `tokenizar` varre o texto **uma vez**, caractere por caractere (na verdade
/// `Unicode.Scalar` por `Unicode.Scalar` — o mesmo nível que o `AnsiRenderer`
/// usa, mais barato que quebrar em `Character`/grapheme e igualmente seguro
/// aqui: como nunca reordenamos nem juntamos fatias, cortar no meio de um
/// cluster de grafemas entre duas fatias da MESMA cor não corrompe nada — a
/// `String` final continua tendo exatamente os mesmos scalars na mesma ordem).
/// Rodar 20 regex sobre 200 KiB em laço é o que vira segundos de tela travada;
/// aqui é um índice andando pra frente, sem retroceder.
///
/// ## Por que cor por `Color` semântica
///
/// `.secondary`, `.orange`, `.purple`, `.pink`, `.teal` são cores DINÂMICAS do
/// sistema — elas trocam sozinhas entre claro e escuro, o mesmo princípio do
/// `AppAccent.color` (`AppTheme.swift`). Nenhuma tabela de cor dupla aqui.
enum RealceDeSintaxe {
    static func aplicar(_ texto: String, linguagem: Linguagem?) -> AttributedString {
        // `linguagem == nil` (sem regra de realce) e "texto grande demais" caem
        // no mesmo caminho de propósito: as duas situações têm a MESMA saída —
        // devolver o texto sem cor, sem varrer. `texto.utf8.count` é uma
        // contagem de bytes (o teto é em KiB), não de caracteres.
        guard let linguagem, texto.utf8.count <= LimitesDeArquivo.tetoDeRealce else {
            return AttributedString(texto)
        }
        if linguagem == .markdown {
            return RealceMarkdown.aplicar(texto)
        }
        guard let regra = regras[linguagem] else {
            // Não deveria acontecer (toda linguagem do enum tem linha na
            // tabela) — mas se uma nova linguagem for acrescentada ao
            // `Linguagem` sem a linha correspondente aqui, cair pra sem-cor é
            // mais seguro do que travar a tela.
            return AttributedString(texto)
        }
        return tokenizar(texto, regra: regra)
    }

    // MARK: - Categorias e cores

    private enum Categoria: Equatable {
        case normal, comentario, string, numero, palavraChave, tipo

        var cor: Color? {
            switch self {
            case .normal:       return nil
            case .comentario:   return .secondary
            case .string:       return .orange
            case .numero:       return .purple
            case .palavraChave: return .pink
            case .tipo:         return .teal
            }
        }
    }

    private static func formatar(_ trecho: String, categoria: Categoria) -> AttributedString {
        var attr = AttributedString(trecho)
        if let cor = categoria.cor { attr.foregroundColor = cor }
        return attr
    }

    // MARK: - A linguagem como dado

    /// Tudo que o tokenizador genérico precisa saber sobre UMA linguagem. Isto
    /// não é um objeto de configuração incidental — É o mecanismo que evita o
    /// switch gigante: acrescentar linguagem vira acrescentar uma linha em
    /// `regras`, nunca um novo caminho de código.
    private struct RegraDeLinguagem {
        var palavrasChave: Set<String>
        /// Marcador de comentário até o fim da linha (`//`, `#`, `--`). `nil` =
        /// a linguagem não tem.
        var comentarioDeLinha: String?
        /// Par abre/fecha do comentário de bloco (`/*` `*/`, `<!--` `-->`).
        /// `nil` = a linguagem não tem.
        var comentarioDeBloco: (abre: String, fecha: String)?
        /// Caracteres que abrem/fecham string — cada aspas só fecha com o
        /// MESMO caractere (aspas simples não fecha aspas duplas).
        var aspas: Set<Unicode.Scalar>
        /// SQL, HTML e CSS têm "palavra-chave" que na prática não distingue
        /// maiúscula de minúscula (`SELECT`/`select`, `<DIV>`/`<div>`). Nas
        /// linguagens de programação de verdade isso é `false`: colorir uma
        /// variável Swift chamada `IF` como se fosse a palavra-chave `if`
        /// seria um bug, não um acerto.
        var palavraChaveIgnoraCaixa: Bool = false
    }

    private static let aspasPadrao: Set<Unicode.Scalar> = ["\"", "'"]

    private static let regras: [Linguagem: RegraDeLinguagem] = [
        .swift: RegraDeLinguagem(
            // "Self" (maiúsculo) fica DE FORA de propósito: é o caso que o
            // comentário de `categoriaDoIdentificador` cita — a checagem de
            // palavra-chave vem antes da de tipo, então listar "Self" aqui
            // impediria a regra geral de maiúscula de classificá-lo como tipo
            // (12/08/2026 — achado pelo teste
            // `testIdentificadorComecandoComMaiusculaViraTipo`). "self"
            // minúsculo continua palavra-chave normalmente.
            palavrasChave: [
                "func", "var", "let", "if", "else", "for", "while", "return", "class", "struct",
                "enum", "protocol", "extension", "guard", "switch", "case", "default", "break",
                "continue", "import", "private", "public", "internal", "fileprivate", "static",
                "self", "nil", "true", "false", "in", "is", "as", "try", "catch", "throw",
                "throws", "rethrows", "async", "await", "where", "init", "deinit", "typealias",
                "associatedtype", "operator", "subscript", "defer", "repeat", "do", "fallthrough",
                "inout", "mutating", "override", "final", "lazy", "weak", "unowned", "some", "any",
                "willSet", "didSet", "get", "set",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\""]
        ),
        .go: RegraDeLinguagem(
            palavrasChave: [
                "func", "var", "const", "if", "else", "for", "range", "return", "package", "import",
                "type", "struct", "interface", "map", "chan", "go", "defer", "switch", "case",
                "default", "break", "continue", "fallthrough", "select", "goto", "nil", "true",
                "false", "iota",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\"", "`"]
        ),
        .typescript: RegraDeLinguagem(
            palavrasChave: [
                "function", "var", "let", "const", "if", "else", "for", "while", "return", "class",
                "extends", "new", "this", "super", "try", "catch", "finally", "throw", "async",
                "await", "yield", "typeof", "instanceof", "in", "of", "null", "undefined", "true",
                "false", "void", "delete", "break", "continue", "switch", "case", "do", "static",
                "get", "set", "import", "export", "default", "from", "as", "interface", "implements",
                "type", "namespace", "declare", "abstract", "readonly", "enum", "public", "private",
                "protected",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\"", "'", "`"]
        ),
        .javascript: RegraDeLinguagem(
            palavrasChave: [
                "function", "var", "let", "const", "if", "else", "for", "while", "return", "class",
                "extends", "new", "this", "super", "try", "catch", "finally", "throw", "async",
                "await", "yield", "typeof", "instanceof", "in", "of", "null", "undefined", "true",
                "false", "void", "delete", "break", "continue", "switch", "case", "do", "static",
                "get", "set", "import", "export", "default", "from", "as",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\"", "'", "`"]
        ),
        .python: RegraDeLinguagem(
            palavrasChave: [
                "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass",
                "break", "continue", "global", "nonlocal", "assert", "del", "is", "in", "not", "and",
                "or", "None", "True", "False", "async", "await", "self",
            ],
            comentarioDeLinha: "#", comentarioDeBloco: nil, aspas: aspasPadrao
        ),
        .ruby: RegraDeLinguagem(
            palavrasChave: [
                "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until",
                "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require",
                "require_relative", "nil", "true", "false", "self", "and", "or", "not", "then",
                "case", "when", "break", "next", "redo", "retry", "super", "private", "public",
                "protected", "attr_accessor", "attr_reader", "attr_writer",
            ],
            comentarioDeLinha: "#", comentarioDeBloco: nil, aspas: aspasPadrao
        ),
        .rust: RegraDeLinguagem(
            // "Self", "None", "Some", "Ok" e "Err" (maiúsculos) ficam DE FORA de
            // propósito — MESMO caso do "Self" do Swift logo acima na tabela: a
            // checagem de palavra-chave vem antes da de tipo em
            // `categoriaDoIdentificador`, então listá-los aqui impediria a regra
            // geral de maiúscula de colori-los como tipo (12/08/2026 — achado de
            // revisão adversarial da Task R: o comentário de
            // `categoriaDoIdentificador` já citava "`Ok`/`Err` do Rust" como
            // exemplo funcionando, mas a tabela aqui contradizia o próprio
            // comentário até esta correção). "self" minúsculo continua
            // palavra-chave normalmente — só a convenção Maiúscula-vira-tipo
            // muda de lado.
            palavrasChave: [
                "fn", "let", "mut", "const", "if", "else", "for", "while", "loop", "return", "struct",
                "enum", "impl", "trait", "pub", "use", "mod", "match", "self", "super",
                "crate", "where", "async", "await", "move", "ref", "dyn", "unsafe", "extern",
                "static", "type", "as", "in", "break", "continue", "true", "false",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\""]
        ),
        .java: RegraDeLinguagem(
            palavrasChave: [
                "class", "interface", "extends", "implements", "public", "private", "protected",
                "static", "final", "void", "if", "else", "for", "while", "do", "return", "new",
                "this", "super", "try", "catch", "finally", "throw", "throws", "import", "package",
                "enum", "switch", "case", "default", "break", "continue", "instanceof", "null",
                "true", "false", "abstract", "synchronized", "volatile", "transient", "native",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao
        ),
        .kotlin: RegraDeLinguagem(
            palavrasChave: [
                "fun", "val", "var", "if", "else", "for", "while", "do", "return", "class",
                "interface", "object", "package", "import", "is", "as", "in", "when", "null", "true",
                "false", "override", "private", "public", "protected", "internal", "companion",
                "data", "sealed", "open", "abstract", "suspend", "try", "catch", "finally", "throw",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao
        ),
        .c: RegraDeLinguagem(
            palavrasChave: [
                "int", "char", "float", "double", "void", "if", "else", "for", "while", "do",
                "return", "struct", "union", "enum", "typedef", "static", "const", "extern",
                "sizeof", "switch", "case", "default", "break", "continue", "goto", "unsigned",
                "signed", "long", "short", "volatile", "register", "NULL",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao
        ),
        .cpp: RegraDeLinguagem(
            palavrasChave: [
                "int", "char", "float", "double", "void", "if", "else", "for", "while", "do",
                "return", "struct", "union", "enum", "typedef", "static", "const", "extern",
                "sizeof", "switch", "case", "default", "break", "continue", "goto", "unsigned",
                "signed", "long", "short", "volatile", "register", "class", "public", "private",
                "protected", "namespace", "using", "template", "typename", "new", "delete", "this",
                "virtual", "override", "try", "catch", "throw", "nullptr", "true", "false", "auto",
                "constexpr",
            ],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao
        ),
        .shell: RegraDeLinguagem(
            palavrasChave: [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                "function", "return", "exit", "export", "local", "echo", "in", "until", "select",
            ],
            comentarioDeLinha: "#", comentarioDeBloco: nil, aspas: aspasPadrao
        ),
        .yaml: RegraDeLinguagem(
            palavrasChave: ["true", "false", "null", "yes", "no"],
            comentarioDeLinha: "#", comentarioDeBloco: nil, aspas: aspasPadrao,
            palavraChaveIgnoraCaixa: true
        ),
        .toml: RegraDeLinguagem(
            palavrasChave: ["true", "false"],
            comentarioDeLinha: "#", comentarioDeBloco: nil, aspas: aspasPadrao
        ),
        .sql: RegraDeLinguagem(
            palavrasChave: [
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "alter", "drop", "join", "left", "right", "inner", "outer", "on",
                "group", "by", "order", "having", "and", "or", "not", "null", "is", "in", "like",
                "limit", "offset", "as", "distinct", "union", "all", "exists", "primary", "key",
                "foreign", "references", "default", "index", "view", "trigger", "begin", "commit",
                "rollback", "transaction",
            ],
            comentarioDeLinha: "--", comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao,
            palavraChaveIgnoraCaixa: true
        ),
        // O comentário de `TipoDeArquivo.swift` já explica: XML e plist usam o
        // MESMO ruleset de HTML porque o que importa colorir é o mesmo (tag,
        // atributo, texto entre aspas, comentário). "Palavra-chave" aqui é o
        // nome de tag mais comum — não existe reconhecimento de tag genérico
        // sem virar um parser de verdade, e isto não é um parser de verdade.
        .html: RegraDeLinguagem(
            palavrasChave: [
                "html", "head", "body", "div", "span", "a", "p", "ul", "ol", "li", "table", "tr",
                "td", "th", "thead", "tbody", "form", "input", "button", "label", "img", "script",
                "style", "link", "meta", "title", "header", "footer", "nav", "section", "article",
                "aside", "main", "h1", "h2", "h3", "h4", "h5", "h6", "br", "hr", "svg", "path",
                "doctype",
            ],
            comentarioDeLinha: nil, comentarioDeBloco: ("<!--", "-->"), aspas: aspasPadrao,
            palavraChaveIgnoraCaixa: true
        ),
        .css: RegraDeLinguagem(
            palavrasChave: [
                "color", "background", "margin", "padding", "display", "position", "width",
                "height", "font", "border", "flex", "grid", "top", "left", "right", "bottom",
                "absolute", "relative", "fixed", "none", "block", "inline", "auto", "important",
            ],
            comentarioDeLinha: nil, comentarioDeBloco: ("/*", "*/"), aspas: aspasPadrao,
            palavraChaveIgnoraCaixa: true
        ),
        // `//` como comentário de linha é bônus pro JSONC (`.jsonc`/`.geojson`
        // também caem em `.json` — ver `TipoDeArquivo.jsons`): JSON de verdade
        // não tem comentário, então nunca aparece um `//` fora de string num
        // `.json` válido, e o realce não "inventa" comentário onde não há.
        .json: RegraDeLinguagem(
            palavrasChave: ["true", "false", "null"],
            comentarioDeLinha: "//", comentarioDeBloco: ("/*", "*/"), aspas: ["\""]
        ),
    ]

    // MARK: - O tokenizador genérico (uma passada, `Unicode.Scalar` por vez)

    /// A varredura em si. Em cada posição, tenta na ordem: comentário de
    /// bloco, comentário de linha, string, identificador (palavra-chave / tipo
    /// / normal), número — e só avança 1 se nada bateu. A ORDEM importa: string
    /// vem antes de comentário-dentro-de-string ser sequer possível, porque uma
    /// vez que uma string começa, `fimDaString` consome tudo até fechar SEM
    /// voltar a checar marcador de comentário no meio dela.
    private static func tokenizar(_ texto: String, regra: RegraDeLinguagem) -> AttributedString {
        let s = Array(texto.unicodeScalars)
        let n = s.count
        var i = 0
        var bufferInicio = 0
        var resultado = AttributedString()

        func flushNormal(ate fim: Int) {
            guard fim > bufferInicio else { return }
            resultado += formatar(fatiar(s, bufferInicio, fim), categoria: .normal)
            bufferInicio = fim
        }

        while i < n {
            if let bloco = regra.comentarioDeBloco, casa(s, i, bloco.abre) {
                let fim = fimDoComentarioDeBloco(s, aposAbrir: i + bloco.abre.count, fecha: bloco.fecha)
                flushNormal(ate: i)
                resultado += formatar(fatiar(s, i, fim), categoria: .comentario)
                i = fim; bufferInicio = fim
                continue
            }
            if let marcador = regra.comentarioDeLinha, casa(s, i, marcador) {
                let fim = fimDaLinha(s, desde: i)
                flushNormal(ate: i)
                resultado += formatar(fatiar(s, i, fim), categoria: .comentario)
                i = fim; bufferInicio = fim
                continue
            }
            if regra.aspas.contains(s[i]) {
                let fim = fimDaString(s, desde: i, aspas: s[i])
                flushNormal(ate: i)
                resultado += formatar(fatiar(s, i, fim), categoria: .string)
                i = fim; bufferInicio = fim
                continue
            }
            if ehLetra(s[i]) || s[i] == "_" {
                let fim = fimDoIdentificador(s, desde: i)
                let token = fatiar(s, i, fim)
                let categoria = categoriaDoIdentificador(token, regra: regra)
                if categoria != .normal {
                    flushNormal(ate: i)
                    resultado += formatar(token, categoria: categoria)
                    bufferInicio = fim
                }
                i = fim
                continue
            }
            if ehDigito(s[i]) {
                let fim = fimDoNumero(s, desde: i)
                flushNormal(ate: i)
                resultado += formatar(fatiar(s, i, fim), categoria: .numero)
                i = fim; bufferInicio = fim
                continue
            }
            i += 1
        }
        flushNormal(ate: n)
        return resultado
    }

    private static func categoriaDoIdentificador(_ token: String, regra: RegraDeLinguagem) -> Categoria {
        let chave = regra.palavraChaveIgnoraCaixa ? token.lowercased() : token
        if regra.palavrasChave.contains(chave) { return .palavraChave }
        // "Tipo" é regra GERAL (não dado por linguagem): identificador que
        // começa com maiúscula. Vale pro `Self` do Swift, pro `String` do Go,
        // pro `Ok`/`Err` do Rust — nenhuma linguagem precisa listar seus tipos,
        // a convenção de capitalização já entrega a resposta.
        if let primeiro = token.unicodeScalars.first, ehMaiuscula(primeiro) { return .tipo }
        return .normal
    }

    // MARK: - Fins de token (cada um devolve o índice EXCLUSIVO de parada)

    private static func fimDaLinha(_ s: [Unicode.Scalar], desde i: Int) -> Int {
        var j = i
        while j < s.count, s[j] != "\n" { j += 1 }
        return j
    }

    /// Se o fechamento não aparecer, o comentário vai até o fim do arquivo —
    /// é o caso de "comentário no fim do arquivo sem quebra de linha" E o de
    /// bloco de comentário nunca fechado. Nenhum dos dois é erro aqui: colorir
    /// o resto do arquivo como comentário é o comportamento certo (mais perto
    /// da intenção de quem escreveu do que parar de colorir no meio).
    private static func fimDoComentarioDeBloco(_ s: [Unicode.Scalar], aposAbrir: Int, fecha: String) -> Int {
        let n = s.count
        var j = aposAbrir
        while j < n {
            if casa(s, j, fecha) { return j + fecha.count }
            j += 1
        }
        return n
    }

    /// `\` escapa o PRÓXIMO caractere sem checar o que é — inclusive quando
    /// esse caractere é a própria aspa. É por isso que `\"` dentro de uma
    /// string não fecha ela, e é por isso que uma sequência de comentário
    /// (`//`) dentro da string nunca é vista: esta função consome os
    /// caracteres direto, sem devolver o controle pro laço principal até
    /// achar a aspa de fechamento (ou o fim do arquivo).
    private static func fimDaString(_ s: [Unicode.Scalar], desde i: Int, aspas: Unicode.Scalar) -> Int {
        let n = s.count
        var j = i + 1
        while j < n {
            if s[j] == "\\", j + 1 < n { j += 2; continue }
            if s[j] == aspas { return j + 1 }
            j += 1
        }
        return n // aspa nunca fechou — string não fechada até o fim do arquivo
    }

    private static func fimDoIdentificador(_ s: [Unicode.Scalar], desde i: Int) -> Int {
        var j = i + 1
        // Consome dígitos junto do identificador — é o que impede "x1" de
        // virar identificador "x" + número "1" colados sem separador.
        while j < s.count, ehLetra(s[j]) || ehDigito(s[j]) || s[j] == "_" { j += 1 }
        return j
    }

    /// Não é um parser de literal numérico completo (não cobre sufixo de tipo
    /// tipo `1_000u32` do Rust, por exemplo) — cobre inteiro, decimal, hex
    /// (`0x`) e notação científica (`1e10`, `1.5e-3`), que é o que aparece na
    /// prática em código lido no celular. Errar aqui pinta um dígito a menos
    /// de roxo, nunca esconde texto.
    private static func fimDoNumero(_ s: [Unicode.Scalar], desde i: Int) -> Int {
        let n = s.count
        if s[i] == "0", i + 1 < n, s[i + 1] == "x" || s[i + 1] == "X" {
            var j = i + 2
            while j < n, hexDigitos.contains(s[j]) { j += 1 }
            return j
        }
        var j = i
        while j < n, ehDigito(s[j]) { j += 1 }
        if j < n, s[j] == ".", j + 1 < n, ehDigito(s[j + 1]) {
            j += 1
            while j < n, ehDigito(s[j]) { j += 1 }
        }
        if j < n, s[j] == "e" || s[j] == "E" {
            var k = j + 1
            if k < n, s[k] == "+" || s[k] == "-" { k += 1 }
            if k < n, ehDigito(s[k]) {
                j = k
                while j < n, ehDigito(s[j]) { j += 1 }
            }
        }
        return j
    }

    // MARK: - Utilidades de scalar (compartilhadas com o ruleset de markdown)

    private static let hexDigitos = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    private static func ehLetra(_ c: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(c) }
    private static func ehDigito(_ c: Unicode.Scalar) -> Bool { CharacterSet.decimalDigits.contains(c) }
    private static func ehMaiuscula(_ c: Unicode.Scalar) -> Bool { CharacterSet.uppercaseLetters.contains(c) }

    /// Compara `marcador` (`"//"`, `"/*"`, `"<!--"`...) contra `s` a partir de
    /// `i`, sem alocar nada por chamada além do próprio marcador convertido —
    /// e o marcador é sempre curto (no máximo 4 scalars nesta tabela).
    private static func casa(_ s: [Unicode.Scalar], _ i: Int, _ marcador: String) -> Bool {
        let m = Array(marcador.unicodeScalars)
        guard i + m.count <= s.count else { return false }
        for k in 0..<m.count where s[i + k] != m[k] { return false }
        return true
    }

    private static func fatiar(_ s: [Unicode.Scalar], _ a: Int, _ b: Int) -> String {
        guard a < b else { return "" }
        var r = ""
        r.unicodeScalars.append(contentsOf: s[a..<b])
        return r
    }

    // MARK: - Markdown: ruleset próprio

    /// Markdown não cabe na tabela de `RegraDeLinguagem` (não tem "palavra-
    /// chave" nem comentário — tem título, ênfase, código, link, lista,
    /// citação), então ganha o próprio mini-tokenizador. Fica ANINHADO dentro
    /// de `RealceDeSintaxe` (não solto no arquivo) só para poder reusar, sem
    /// duplicar, as funções `private` de scalar acima (`fatiar`, `casa`,
    /// `fimDaLinha`...) e a tabela `regras` — Swift dá a um tipo aninhado
    /// acesso ao `private` do tipo que o contém.
    private enum RealceMarkdown {
        static func aplicar(_ texto: String) -> AttributedString {
            let s = Array(texto.unicodeScalars)
            let n = s.count
            var i = 0
            var bufferInicio = 0
            var inicioDeLinha = true
            var resultado = AttributedString()

            func flushNormal(ate fim: Int) {
                guard fim > bufferInicio else { return }
                resultado += AttributedString(RealceDeSintaxe.fatiar(s, bufferInicio, fim))
                bufferInicio = fim
            }

            func estilizado(_ a: Int, _ b: Int, cor: Color? = nil, intent: InlinePresentationIntent? = nil) -> AttributedString {
                var attr = AttributedString(RealceDeSintaxe.fatiar(s, a, b))
                if let cor { attr.foregroundColor = cor }
                if let intent { attr.inlinePresentationIntent = intent }
                return attr
            }

            while i < n {
                if inicioDeLinha {
                    inicioDeLinha = false

                    if let bloco = detectarBlocoDeCodigo(s, desde: i) {
                        flushNormal(ate: i)
                        resultado += estilizado(i, bloco.inicioConteudo, cor: .secondary)
                        if bloco.fimConteudo > bloco.inicioConteudo {
                            if let linguagem = bloco.linguagem, linguagem == .markdown {
                                resultado += aplicar(RealceDeSintaxe.fatiar(s, bloco.inicioConteudo, bloco.fimConteudo))
                            } else if let linguagem = bloco.linguagem, let regra = RealceDeSintaxe.regras[linguagem] {
                                resultado += RealceDeSintaxe.tokenizar(
                                    RealceDeSintaxe.fatiar(s, bloco.inicioConteudo, bloco.fimConteudo), regra: regra
                                )
                            } else {
                                // Linguagem da cerca desconhecida (ou ausente):
                                // só monoespaçado, SEM passar pelo resto deste
                                // laço — é o que impede `**isto**` dentro da
                                // cerca de virar negrito como se fosse prosa.
                                resultado += estilizado(bloco.inicioConteudo, bloco.fimConteudo, intent: .code)
                            }
                        }
                        if let inicioFechamento = bloco.inicioFechamento, let fimFechamento = bloco.fimFechamento {
                            resultado += estilizado(inicioFechamento, fimFechamento, cor: .secondary)
                            i = fimFechamento
                        } else {
                            i = bloco.fimConteudo
                        }
                        bufferInicio = i
                        inicioDeLinha = true
                        continue
                    }

                    if ehTitulo(s, i) {
                        let fimLinha = fimDaLinha(s, desde: i)
                        flushNormal(ate: i)
                        resultado += estilizado(i, fimLinha, intent: .stronglyEmphasized)
                        i = fimLinha
                        bufferInicio = i
                        continue
                    }

                    if s[i] == ">" {
                        flushNormal(ate: i)
                        resultado += estilizado(i, i + 1, cor: .secondary)
                        i += 1
                        bufferInicio = i
                        continue
                    }

                    if let fimMarcador = fimDeMarcadorDeLista(s, desde: i) {
                        flushNormal(ate: i)
                        resultado += estilizado(i, fimMarcador, cor: .secondary)
                        i = fimMarcador
                        bufferInicio = i
                        continue
                    }
                }

                // Negrito (`**` / `__`) — checado antes de itálico de propósito:
                // sem isso, o primeiro `*` de um `**` seria lido como abertura
                // de itálico e nunca sobraria um segundo `*` pra fechar o
                // negrito certo.
                if casa(s, i, "**") || casa(s, i, "__") {
                    let marcador = RealceDeSintaxe.fatiar(s, i, i + 2)
                    if let fim = fimDoFechamento(s, desde: i + 2, marcador: marcador) {
                        flushNormal(ate: i)
                        resultado += estilizado(i, fim, intent: .stronglyEmphasized)
                        i = fim; bufferInicio = i
                        continue
                    }
                }
                if s[i] == "*" || s[i] == "_" {
                    let marcador = RealceDeSintaxe.fatiar(s, i, i + 1)
                    if let fim = fimDoFechamento(s, desde: i + 1, marcador: marcador) {
                        flushNormal(ate: i)
                        resultado += estilizado(i, fim, intent: .emphasized)
                        i = fim; bufferInicio = i
                        continue
                    }
                }
                if s[i] == "`" {
                    if let fim = fimDoFechamento(s, desde: i + 1, marcador: "`") {
                        flushNormal(ate: i)
                        resultado += estilizado(i, fim, intent: .code)
                        i = fim; bufferInicio = i
                        continue
                    }
                }
                if s[i] == "[", let fim = fimDeLink(s, desde: i) {
                    flushNormal(ate: i)
                    resultado += estilizado(i, fim, cor: .blue)
                    i = fim; bufferInicio = i
                    continue
                }

                if s[i] == "\n" { inicioDeLinha = true }
                i += 1
            }
            flushNormal(ate: n)
            return resultado
        }

        /// Busca o fechamento de um marcador de ênfase/código **sem cruzar
        /// quebra de linha** — é o que garante que a busca é O(tamanho da
        /// linha), não O(tamanho do arquivo): num arquivo de 200 KiB com um
        /// `**` solto logo no início e nenhum outro depois, sem este limite a
        /// varredura andaria até o fim do arquivo UMA vez (aceitável), mas com
        /// várias marcações soltas em várias linhas o custo somado continua
        /// linear porque cada busca para na primeira quebra de linha.
        private static func fimDoFechamento(_ s: [Unicode.Scalar], desde inicio: Int, marcador: String) -> Int? {
            let m = Array(marcador.unicodeScalars)
            var j = inicio
            let n = s.count
            while j < n, s[j] != "\n" {
                if j + m.count <= n {
                    var igual = true
                    for k in 0..<m.count where s[j + k] != m[k] { igual = false; break }
                    if igual { return j + m.count }
                }
                j += 1
            }
            return nil
        }

        private static func fimDeLink(_ s: [Unicode.Scalar], desde i: Int) -> Int? {
            guard let fimColchete = fimDoFechamento(s, desde: i + 1, marcador: "]") else { return nil }
            guard fimColchete < s.count, s[fimColchete] == "(" else { return nil }
            return fimDoFechamento(s, desde: fimColchete + 1, marcador: ")")
        }

        private static func fimDeMarcadorDeLista(_ s: [Unicode.Scalar], desde i: Int) -> Int? {
            let n = s.count
            guard i < n else { return nil }
            if s[i] == "-" || s[i] == "*" || s[i] == "+", i + 1 < n, s[i + 1] == " " {
                return i + 2
            }
            var j = i
            while j < n, RealceDeSintaxe.ehDigito(s[j]) { j += 1 }
            if j > i, j < n, s[j] == ".", j + 1 < n, s[j + 1] == " " {
                return j + 2
            }
            return nil
        }

        private static func ehTitulo(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
            var j = i
            let n = s.count
            while j < n, s[j] == "#" { j += 1 }
            let quantidade = j - i
            return quantidade >= 1 && quantidade <= 6 && j < n && s[j] == " "
        }

        private static func fimDaLinha(_ s: [Unicode.Scalar], desde i: Int) -> Int {
            RealceDeSintaxe.fimDaLinha(s, desde: i)
        }

        private static func casa(_ s: [Unicode.Scalar], _ i: Int, _ marcador: String) -> Bool {
            RealceDeSintaxe.casa(s, i, marcador)
        }

        // MARK: Cerca de código (```/~~~)

        private struct BlocoDeCodigo {
            let inicioConteudo: Int
            let fimConteudo: Int
            let linguagem: Linguagem?
            /// `nil` nos dois juntos = a cerca nunca fechou; o bloco vai até o
            /// fim do arquivo (mesma regra do comentário de bloco: colorir até
            /// o fim é mais seguro do que travar procurando um fechamento que
            /// não existe).
            let inicioFechamento: Int?
            let fimFechamento: Int?
        }

        /// Reconhece uma cerca de código (` ``` ` ou `~~~`, 3 ou mais) na
        /// posição `i` — que só é chamada em início de linha — e acha onde ela
        /// fecha. A tag de linguagem (o que vem depois da cerca de abertura,
        /// tipo "swift" em ` ```swift `) decide se o miolo é recolorido pelo
        /// tokenizador daquela linguagem ou só fica monoespaçado.
        private static func detectarBlocoDeCodigo(_ s: [Unicode.Scalar], desde i: Int) -> BlocoDeCodigo? {
            let n = s.count
            guard i < n, s[i] == "`" || s[i] == "~" else { return nil }
            let marcador = s[i]
            var j = i
            while j < n, s[j] == marcador { j += 1 }
            let tamanhoCerca = j - i
            guard tamanhoCerca >= 3 else { return nil }

            let fimLinhaAbertura = fimDaLinha(s, desde: j)
            let tag = RealceDeSintaxe.fatiar(s, j, fimLinhaAbertura).trimmingCharacters(in: .whitespaces)
            let linguagem = linguagemPorApelido(tag)
            let inicioConteudo = fimLinhaAbertura < n ? fimLinhaAbertura + 1 : fimLinhaAbertura

            var k = inicioConteudo
            while k < n {
                var m = k
                while m < n, s[m] == marcador { m += 1 }
                if m - k >= tamanhoCerca {
                    let fimLinhaFechamento = fimDaLinha(s, desde: k)
                    let fimFechamento = fimLinhaFechamento < n ? fimLinhaFechamento + 1 : fimLinhaFechamento
                    return BlocoDeCodigo(
                        inicioConteudo: inicioConteudo, fimConteudo: k, linguagem: linguagem,
                        inicioFechamento: k, fimFechamento: fimFechamento
                    )
                }
                let fimDestaLinha = fimDaLinha(s, desde: k)
                k = fimDestaLinha < n ? fimDestaLinha + 1 : n
            }
            return BlocoDeCodigo(
                inicioConteudo: inicioConteudo, fimConteudo: n, linguagem: linguagem,
                inicioFechamento: nil, fimFechamento: nil
            )
        }

        /// Apelidos comuns de linguagem em cerca de código (` ```js `,
        /// ` ```sh `...) que não batem com o `rawValue` do `Linguagem` direto.
        private static func linguagemPorApelido(_ tagBruta: String) -> Linguagem? {
            let tag = tagBruta.lowercased()
            guard !tag.isEmpty else { return nil }
            if let direta = Linguagem(rawValue: tag) { return direta }
            let apelidos: [String: Linguagem] = [
                "js": .javascript, "jsx": .javascript, "mjs": .javascript, "node": .javascript,
                "tsx": .typescript,
                "py": .python, "py3": .python,
                "rb": .ruby,
                "rs": .rust,
                "kt": .kotlin, "kts": .kotlin,
                "c++": .cpp, "cxx": .cpp,
                "sh": .shell, "bash": .shell, "zsh": .shell, "console": .shell,
                "yml": .yaml,
                "xml": .html, "htm": .html,
                "md": .markdown,
            ]
            return apelidos[tag]
        }
    }
}
