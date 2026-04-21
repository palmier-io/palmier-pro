import SwiftUI

struct AgentMessageView: View {
    let message: AgentMessage
    /// Indexed by `tool_use_id` — an assistant's `tool_use` block renders with
    /// its matching result inline so the UI shows one combined row.
    let toolResults: [String: ToolRunResult]

    var body: some View {
        switch message.role {
        case .user:   userBody
        case .assistant: assistantBody
        }
    }

    @ViewBuilder
    private var userBody: some View {
        let texts = message.blocks.compactMap { block -> String? in
            if case let .text(s) = block { return s }
            return nil
        }
        if !texts.isEmpty {
            HStack {
                Spacer(minLength: 48)
                Text(texts.joined(separator: "\n"))
                    .font(.body)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .textSelection(.enabled)
            }
        }
        // Tool-result messages are merged into the preceding assistant row, so we
        // render nothing for pure tool_result user messages.
    }

    @ViewBuilder
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolUse(let id, let name, let input):
                    ToolRunRow(name: name, input: input.value, result: toolResults[id])
                case .toolResult:
                    EmptyView()
                }
            }
        }
    }
}

struct ToolRunResult {
    let content: [ToolResult.Block]
    let isError: Bool
}

private struct ToolRunRow: View {
    let name: String
    let input: [String: Any]
    let result: ToolRunResult?
    @State private var expanded = false

    private var statusIcon: String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }
    private var statusTint: Color {
        guard let result else { return AppTheme.Text.mutedColor }
        return result.isError ? .red.opacity(0.8) : AppTheme.Text.tertiaryColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(statusTint)
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    argsSection
                    if let result { resultSection(result) }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .textSelection(.enabled)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var argsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("args").font(.system(size: 9)).foregroundStyle(AppTheme.Text.mutedColor)
            Text(jsonPreview(input))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func resultSection(_ r: ToolRunResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(r.isError ? "error" : "result")
                .font(.system(size: 9))
                .foregroundStyle(r.isError ? .red.opacity(0.75) : AppTheme.Text.mutedColor)
            ForEach(Array(r.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(s).frame(maxWidth: .infinity, alignment: .leading)
                case .image:
                    Text("(image payload)").foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
        }
    }

    private func jsonPreview(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else {
            return "(no args)"
        }
        return s
    }
}
