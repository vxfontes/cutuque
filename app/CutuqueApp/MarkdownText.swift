import SwiftUI

// MARK: - Renderer de Markdown para as respostas do Claude

/// Renderiza o markdown que o Claude devolve como SwiftUI nativo: negrito,
/// itálico e código inline (via AttributedString), além de títulos, listas,
/// citações, blocos de código e tabelas. Feito à mão (sem dependências) para
/// rodar no device sem alterar o build.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            inline(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let lang, let code):
            codeCard(lang: lang, code: code)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.body).foregroundStyle(.secondary)
                        inline(item).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        inline(item).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                inline(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .rule:
            Divider()
        }
    }

    // MARK: Bloco de código (com chip de linguagem e coloração de diff)

    @ViewBuilder
    private func codeCard(lang: String, code: String) -> some View {
        let isDiff = Self.looksLikeDiff(lang: lang, code: code)
        VStack(alignment: .leading, spacing: 0) {
            if !lang.isEmpty || isDiff {
                Text(isDiff ? "diff" : lang.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                if isDiff {
                    diffBody(code)
                } else {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Renderiza um diff colorindo + (verde) / - (vermelho) / @@ (destaque).
    private func diffBody(_ code: String) -> some View {
        let lines = code.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Self.diffColor(line))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private static func diffColor(_ line: String) -> Color {
        if line.hasPrefix("@@") { return .cyan }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    /// Diff se a linguagem é "diff"/"patch", ou se o conteúdo tem cara de diff
    /// (hunk @@ ou várias linhas +/-).
    private static func looksLikeDiff(lang: String, code: String) -> Bool {
        let l = lang.lowercased()
        if l == "diff" || l == "patch" { return true }
        let lines = code.components(separatedBy: "\n")
        if lines.contains(where: { $0.hasPrefix("@@ ") }) { return true }
        let pm = lines.filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
        return pm >= 3
    }

    // MARK: Tabela

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let cols = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(cells: header, cols: cols, header: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(cells: row, cols: cols, header: false)
                    Divider().opacity(0.4)
                }
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func tableRow(cells: [String], cols: Int, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<cols, id: \.self) { i in
                inline(i < cells.count ? cells[i] : "")
                    .font(header ? .caption.weight(.semibold) : .caption)
                    .frame(minWidth: 90, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Inline

    /// Renderiza markdown inline (negrito/itálico/código/link). Cai em texto
    /// puro se o parser falhar.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title2.weight(.bold)
        case 2:  return .title3.weight(.bold)
        case 3:  return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

// MARK: - Parser de blocos

/// Um bloco de markdown já classificado para renderização.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, String)
    case bullet([String])
    case numbered([String])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    /// Quebra um texto markdown em blocos, por linha. Cobre os elementos que o
    /// Claude usa na prática; o resto vira parágrafo (com inline preservado).
    static func parse(_ md: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var para: [String] = []

        func flushPara() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: "\n")))
                para.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Bloco de código cercado (``` ou ~~~).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPara()
                let fence = String(trimmed.prefix(3))
                // A linguagem vem logo após a cerca de abertura (```swift, ```diff).
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1 // pula a cerca de fechamento
                blocks.append(.code(lang: lang, code.joined(separator: "\n")))
                continue
            }

            // Tabela: linha com | seguida de linha separadora (|---|).
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara()
                let header = splitRow(trimmed)
                var rows: [[String]] = []
                i += 2 // pula header + separador
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Linha em branco: fecha parágrafo.
            if trimmed.isEmpty {
                flushPara(); i += 1; continue
            }

            // Régua horizontal.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara(); blocks.append(.rule); i += 1; continue
            }

            // Título.
            if let h = heading(trimmed) {
                flushPara(); blocks.append(h); i += 1; continue
            }

            // Citação: junta linhas > consecutivas.
            if trimmed.hasPrefix(">") {
                flushPara()
                var quote: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    quote.append(q.trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // Lista com marcador.
            if isBullet(trimmed) {
                flushPara()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // Lista numerada.
            if isNumbered(trimmed) {
                flushPara()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumber(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // Caso geral: acumula no parágrafo.
            para.append(trimmed)
            i += 1
        }
        flushPara()
        return blocks
    }

    // MARK: Helpers de linha

    private static func heading(_ s: String) -> MarkdownBlock? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, s.count > level, s[s.index(s.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let text = String(s.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isNumbered(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: ".") else { return false }
        let num = s[s.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber) && s.index(after: dot) < s.endIndex && s[s.index(after: dot)] == " "
    }

    private static func stripNumber(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        return String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") || t.contains("-") else { return false }
        // Ex.: |---|:--:|---| — só |, -, :, espaço.
        let allowed = Set("|-: ")
        return t.contains("-") && t.allSatisfy { allowed.contains($0) }
    }

    private static func splitRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
