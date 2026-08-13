import XCTest

/// Barreira contra a volta de `Color.accentColor` no alvo do iOS.
///
/// [13/08/2026] Contexto da queixa que originou isto: "mesmo eu trocando a cor,
/// alguns lugares fica com cor padrao". A causa é que `Color.accentColor`
/// **ignora** o `.tint(_:)` da raiz — ele resolve do catálogo de assets, que não
/// tem `AccentColor.colorset`, e volta azul de sistema para sempre. O contrato
/// do app é `@Environment(\.corDeDestaque)` (ver `AppTheme.swift`).
///
/// A varredura que consertou isso foi manual, arquivo por arquivo. Sem uma
/// barreira, o próximo `Color.accentColor` escrito por reflexo reabre a queixa
/// calado — nada quebra, nada avisa, só uma tela volta a ficar azul. Este teste
/// é a barreira: roda dentro do mesmo `xcodebuild test` de sempre, sem infra
/// nova, e aponta `arquivo:linha`.
///
/// Sugestão da revisão adversarial da onda 0, que também descartou a alternativa
/// óbvia (criar `AccentColor.colorset` no catálogo): o app escolhe entre 8 temas
/// em tempo de execução, e um Color Set do catálogo não muda por `@AppStorage`.
///
/// Limite conhecido: cobre só este literal. Uma cor fixa nova (`.blue` escrito à
/// mão num botão) não cai aqui — para essas, a alçada é a revisão. Uma
/// allowlist de `.blue` seria ruído puro, porque `.blue` É legítimo em dois
/// lugares (o padrão de `AppAccent` e o azul de `.running`, que não segue a
/// preferência de propósito para não colidir com verde=concluído).
final class BarreiraDeCorDeDestaqueTests: XCTestCase {
    /// Arquivos onde o literal é aceitável, com o motivo. Vazia hoje — e o certo
    /// é que continue vazia: entrar aqui exige justificar por que ESTA tela pode
    /// desobedecer a preferência da usuária.
    private static let liberados: Set<String> = []

    func testNenhumUsoVivoDeAccentColor() throws {
        let fontes = try Self.arquivosDoAlvoIOS()
        // Se a raiz não bate (checkout renomeado, build fora da árvore), falhar
        // aqui seria falso negativo disfarçado de aprovação — melhor gritar.
        XCTAssertGreaterThan(fontes.count, 50,
                             "achei só \(fontes.count) fontes: a varredura não chegou no alvo")

        var infratores: [String] = []
        for url in fontes {
            guard let texto = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let nome = url.lastPathComponent
            guard !Self.liberados.contains(nome) else { continue }
            for (indice, linha) in texto.components(separatedBy: .newlines).enumerated()
            where Self.linhaUsaAccentColor(linha) {
                infratores.append("\(nome):\(indice + 1): \(linha.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(infratores.isEmpty, """
            `Color.accentColor` não segue o `.tint()` da raiz — troque por \
            `@Environment(\\.corDeDestaque)`:
            \(infratores.joined(separator: "\n"))
            """)
    }

    /// Comentário citando o literal é o normal aqui: a varredura deixou uma nota
    /// datada em cada arquivo que consertou, explicando o porquê. Só código
    /// conta.
    private static func linhaUsaAccentColor(_ linha: String) -> Bool {
        let limpa = linha.trimmingCharacters(in: .whitespaces)
        guard !limpa.hasPrefix("//"), !limpa.hasPrefix("*"), !limpa.hasPrefix("/*") else { return false }
        // Código com comentário no fim da linha: só o que vem ANTES do `//`.
        let codigo = limpa.components(separatedBy: "//").first ?? limpa
        return codigo.contains("accentColor")
    }

    /// A raiz vem de `#filePath` (literal de compilação): este arquivo mora em
    /// `<raiz>/app/CutuqueAppTests/`, então dois níveis acima é `app/`.
    private static func arquivosDoAlvoIOS() throws -> [URL] {
        let alvo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CutuqueAppTests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("CutuqueApp")
        let conteudo = try FileManager.default.contentsOfDirectory(
            at: alvo, includingPropertiesForKeys: nil)
        return conteudo.filter { $0.pathExtension == "swift" }
    }
}
