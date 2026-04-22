import SwiftUI

/// Fenced code blocks render as styled panels; inline formatting uses `AttributedString(markdown:)`.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let s):
                    Text(attributed(s))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                case .heading(let level, let s):
                    Text(attributed(s))
                        .font(.system(size: headingSize(level), weight: level <= 1 ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

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
                }
            }
        }
    }

    private func attributed(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
    }

    private enum Segment {
        case text(String)
        case heading(level: Int, text: String)
        case code(language: String?, code: String)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 16
        case 3: return 14
        default: return 13
        }
    }

    private static func segments(of text: String) -> [Segment] {
        var out: [Segment] = []
        var buffer: [String] = []
        let lines = text.components(separatedBy: "\n")
        var idx = 0
        func flushBuffer() {
            if !buffer.isEmpty {
                out.append(.text(buffer.joined(separator: "\n")))
                buffer.removeAll()
            }
        }
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushBuffer()
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
                out.append(.heading(level: level, text: body))
                idx += 1
            } else {
                buffer.append(line)
                idx += 1
            }
        }
        flushBuffer()
        return out
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
