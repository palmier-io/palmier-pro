import SwiftUI

/// Fenced code blocks render as styled panels; inline formatting uses `AttributedString(markdown:)`.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let s):
                    Text(attributed(s))
                        .font(.body)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineSpacing(3)
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
        case code(language: String?, code: String)
    }

    private static func segments(of text: String) -> [Segment] {
        var out: [Segment] = []
        var buffer: [String] = []
        let lines = text.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !buffer.isEmpty {
                    out.append(.text(buffer.joined(separator: "\n")))
                    buffer.removeAll()
                }
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
            } else {
                buffer.append(lines[idx])
                idx += 1
            }
        }
        if !buffer.isEmpty { out.append(.text(buffer.joined(separator: "\n"))) }
        return out
    }
}
