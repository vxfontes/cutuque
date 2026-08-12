import Foundation

/// Linguagem reconhecida pelo realce de sintaxe. Um caso só existe quando há
/// regra de realce para ele — isto não é um catálogo de tudo que se escreve,
/// é a lista do que o `RealceDeSintaxe` sabe colorir.
enum Linguagem: String, CaseIterable, Equatable {
    case swift, go, typescript, javascript, python, ruby, rust, java, kotlin
    case c, cpp, shell, yaml, toml, sql, html, css, json, markdown
}

/// Como um arquivo da máquina deve ser aberto, decidido pela **extensão do
/// nome** (12/08/2026 — leva do preview de arquivos).
///
/// A extensão é o critério certo aqui por uma razão concreta e não estética: o
/// `APIClient.downloadFile` grava o arquivo no tmp **com o nome original**, e o
/// QuickLook escolhe o renderizador pela extensão do arquivo em disco. Ou seja,
/// esta enum e o QuickLook leem exatamente a mesma pista — se ela diz `.imagem`,
/// o QuickLook vai concordar.
///
/// O que a extensão NÃO decide é se o arquivo é legível como texto: quem sabe
/// isso é o hub, que procura byte nulo nos primeiros 8 KiB (`FileContent.binary`).
/// Por isso a casca (`FileViewerView`) roteia por `podeMostrarTexto` e usa este
/// tipo só para escolher *como* mostrar dentro de cada lado.
enum TipoDeArquivo: Equatable {
    case imagem
    case video
    case audio
    case pdf
    case markdown
    case json
    /// Texto comum; a linguagem é `nil` quando não há regra de realce para ela.
    case texto(Linguagem?)
    /// Não reconhecido. Pode ser binário sem preview dedicado (zip, .docx, um
    /// executável) ou um texto sem extensão (`Makefile`, `.gitignore`) — os dois
    /// caem aqui de propósito, porque quem separa é o `binary` do hub.
    case outro

    static func de(nome: String) -> TipoDeArquivo {
        let ext = (nome as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .outro }
        if imagens.contains(ext) { return .imagem }
        if videos.contains(ext) { return .video }
        if audios.contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if markdowns.contains(ext) { return .markdown }
        if jsons.contains(ext) { return .json }
        if let linguagem = linguagens[ext] { return .texto(linguagem) }
        if textosSemLinguagem.contains(ext) { return .texto(nil) }
        return .outro
    }

    /// Tipo que o QuickLook renderiza melhor do que qualquer tela nossa.
    /// Não inclui `.outro`: zip e .docx também abrem no QuickLook, mas quem os
    /// identifica é o `binary` do hub, não a extensão.
    var abreNoPreview: Bool {
        switch self {
        case .imagem, .video, .audio, .pdf: return true
        default: return false
        }
    }

    /// A linguagem a usar quando se mostra o **código-fonte** do arquivo — vale
    /// inclusive para markdown ("ver fonte") e JSON.
    var linguagemDoFonte: Linguagem? {
        switch self {
        case .markdown: return .markdown
        case .json: return .json
        case .texto(let linguagem): return linguagem
        default: return nil
        }
    }

    // MARK: - Tabelas

    // `svg` fica em imagem apesar de ser texto: quem abre um .svg no celular
    // quer VER o desenho, e o QuickLook desenha. Ver o fonte de um SVG é caso
    // de quem está no computador.
    private static let imagens: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
        "bmp", "tiff", "tif", "ico", "avif", "svg",
    ]
    private static let videos: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
    ]
    private static let audios: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg",
    ]
    private static let markdowns: Set<String> = ["md", "markdown", "mdown", "mdx"]
    private static let jsons: Set<String> = ["json", "jsonc", "geojson"]

    private static let linguagens: [String: Linguagem] = [
        "swift": .swift,
        "go": .go,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "py": .python, "pyi": .python,
        "rb": .ruby, "rake": .ruby,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "c": .c, "h": .c,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "sql": .sql,
        // XML e plist entram no ruleset de HTML: o que importa colorir é o mesmo
        // (tag, atributo, texto entre aspas, comentário).
        "html": .html, "htm": .html, "xhtml": .html, "xml": .html, "plist": .html,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
    ]

    private static let textosSemLinguagem: Set<String> = [
        "txt", "log", "conf", "cfg", "ini", "env", "csv", "tsv",
        "properties", "lock", "diff", "patch", "srt", "text", "rst",
    ]
}

/// Tetos da leva do preview (12/08/2026). Ficam juntos porque são a mesma
/// decisão vista de dois ângulos: quanto vale a pena mover pela rede e quanto
/// vale a pena processar na tela.
enum LimitesDeArquivo {
    /// Acima disto o app NÃO baixa sozinho — pergunta antes. O tamanho já vem
    /// na listagem (`FileEntry.size`), então a decisão acontece antes de
    /// qualquer byte sair da máquina.
    static let tetoDePreview: Int64 = 50 * 1024 * 1024

    /// Acima disto o texto abre SEM cor. Colorir 1 MiB custa tempo e memória, e
    /// cor é conforto — conseguir ler e copiar é o que não pode faltar.
    static let tetoDeRealce = 200 * 1024
}
