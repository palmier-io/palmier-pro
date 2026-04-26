import SwiftUI

/// Fenced code blocks render as styled panels; inline + headings collapse into a single
/// AttributedString rendered by one Text view to minimize hosted-text count under LazyVStack.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.cachedParse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let attr):
                    Text(attr)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .textCase(.uppercase)
                        }
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.black.opacity(0.28))
                            )
                    }

                case .table(let header, let rows, let alignments):
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { idx, cell in
                                Text(cell)
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                    .textSelection(.enabled)
                                    .gridColumnAlignment(columnAlign(alignments, at: idx))
                            }
                        }
                        Divider()
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(AppTheme.Text.primaryColor)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.15))
                    )
                }
            }
        }
    }

    private enum Block {
        case prose(AttributedString)
        case code(language: String?, code: String)
        case table(header: [AttributedString], rows: [[AttributedString]], alignments: [TableAlignment])
    }

    enum TableAlignment { case left, center, right }

    private func columnAlign(_ alignments: [TableAlignment], at idx: Int) -> HorizontalAlignment {
        guard idx < alignments.count else { return .leading }
        switch alignments[idx] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private static let cache: NSCache<NSString, CachedBlocks> = {
        let c = NSCache<NSString, CachedBlocks>()
        c.countLimit = 512
        return c
    }()

    private final class CachedBlocks {
        let value: [Block]
        init(_ v: [Block]) { self.value = v }
    }

    private static func cachedParse(_ text: String) -> [Block] {
        if let hit = cache.object(forKey: text as NSString) { return hit.value }
        let value = parse(text)
        cache.setObject(CachedBlocks(value), forKey: text as NSString)
        return value
    }

    private static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var prose = AttributedString()
        var buffer: [String] = []
        let lines = text.components(separatedBy: "\n")
        var idx = 0

        func appendInline(_ raw: String, headingLevel: Int? = nil) {
            if !prose.characters.isEmpty { prose.append(AttributedString("\n\n")) }
            var part = parseInline(raw)
            if let lvl = headingLevel {
                part.font = .system(
                    size: headingSize(lvl),
                    weight: lvl <= 1 ? .bold : .semibold,
                    design: .rounded
                )
            }
            prose.append(part)
        }
        func flushBuffer() {
            if buffer.isEmpty { return }
            appendInline(buffer.joined(separator: "\n"))
            buffer.removeAll()
        }
        func emitProse() {
            flushBuffer()
            guard !prose.characters.isEmpty else { return }
            out.append(.prose(prose))
            prose = AttributedString()
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                emitProse()
                let language = String(trimmed.dropFirst(3))
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count {
                    if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        idx += 1; break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                out.append(.code(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))

            } else if let (level, body) = parseHeading(trimmed) {
                flushBuffer()
                appendInline(body, headingLevel: level)
                idx += 1

            } else if line.contains("|"),
                      idx + 1 < lines.count,
                      let aligns = parseTableSeparator(lines[idx + 1]) {
                let header = splitTableRow(line)
                guard !header.isEmpty else {
                    buffer.append(line); idx += 1; continue
                }
                emitProse()
                idx += 2
                var rows: [[String]] = []
                while idx < lines.count, lines[idx].contains("|"),
                      !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = splitTableRow(lines[idx])
                    while row.count < header.count { row.append("") }
                    if row.count > header.count { row = Array(row.prefix(header.count)) }
                    rows.append(row)
                    idx += 1
                }
                var fullAligns = aligns
                while fullAligns.count < header.count { fullAligns.append(.left) }
                out.append(.table(
                    header: header.map(parseInline),
                    rows: rows.map { $0.map(parseInline) },
                    alignments: Array(fullAligns.prefix(header.count))
                ))

            } else {
                buffer.append(line)
                idx += 1
            }
        }
        emitProse()
        return out
    }

    private static func parseInline(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 16
        case 3: return 14
        default: return 13
        }
    }

    /// GFM separator row: `|---|:--:|---:|` style — dashes per cell with optional colons for alignment.
    private static func parseTableSeparator(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var cells = trimmed.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return nil }
        var aligns: [TableAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            let middle = c.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            guard !middle.isEmpty, middle.allSatisfy({ $0 == "-" }) else { return nil }
            if left && right { aligns.append(.center) }
            else if right { aligns.append(.right) }
            else { aligns.append(.left) }
        }
        return aligns
    }

    private static func splitTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            let ch = trimmed[i]
            let next = trimmed.index(after: i)
            if ch == "\\", next < trimmed.endIndex, trimmed[next] == "|" {
                current.append("|")
                i = trimmed.index(after: next)
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i = next
            } else {
                current.append(ch)
                i = next
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// ATX headings: 1–6 leading `#`s followed by a space and content.
    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1, level <= 6 else { return nil }
        let after = line.index(line.startIndex, offsetBy: level)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let body = line[line.index(after: after)...]
            .trimmingCharacters(in: .whitespaces)
        return (level, body)
    }
}
