import AppKit
import SwiftUI

struct AgentMessageView: View {
    let message: AgentMessage
    let toolResults: [String: ToolRunResult]
    @State private var isHovering = false

    var body: some View {
        switch message.role {
        case .user:   userBody
        case .assistant: assistantBody
        case .system: systemBody
        }
    }

    @ViewBuilder
    private var systemBody: some View {
        let texts = message.blocks.compactMap { block -> String? in
            if case let .text(s) = block { return s }
            return nil
        }
        if !texts.isEmpty {
            HStack {
                Spacer(minLength: 0)
                Text(verbatim: texts.joined(separator: "\n"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 4)
                Spacer(minLength: 0)
            }
        }
    }

    private var copyableText: String {
        message.blocks
            .compactMap { if case let .text(s) = $0 { return s } else { return nil } }
            .joined(separator: "\n\n")
    }

    @ViewBuilder
    private var userBody: some View {
        let texts = message.blocks.compactMap { block -> String? in
            if case let .text(s) = block { return s }
            return nil
        }
        if !texts.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                // User avatar indicator
                Circle()
                    .fill(AppTheme.Accent.primary.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.Accent.primary)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: texts.joined(separator: "\n"))
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.Interaction.fill(AppTheme.Opacity.faint))
            )
        }
        // Tool-result user messages render merged into the preceding assistant row.
    }

    /// A stable identity per block, so a row's own state stays with it while the block list grows.
    ///
    /// Reasoning and non-reasoning blocks are counted separately: reasoning blocks are appended as
    /// they stream and never reordered, whereas a plain index shifts whenever a text block is added
    /// ahead of one, which is what previously let expansion state attach to the wrong row.
    private var renderedBlocks: [(key: String, block: AgentContentBlock)] {
        var reasoning = 0
        var other = 0
        return message.blocks.map { block in
            if block.isReasoning {
                defer { reasoning += 1 }
                return (key: "\(message.id.uuidString)#r\(reasoning)", block: block)
            }
            defer { other += 1 }
            return (key: "\(message.id.uuidString)#o\(other)", block: block)
        }
    }

    @ViewBuilder
    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderedBlocks, id: \.key) { entry in
                let block = entry.block
                switch block {
                case .thinking(let text, let signature):
                    ReasoningBlock(text: text, isComplete: !signature.isEmpty)
                case .redactedThinking(let data):
                    RedactedReasoningBlock(data: data)
                case .openAIReasoning(let summary, _, _, _, let isComplete):
                    ReasoningBlock(text: summary, isComplete: isComplete)
                case .text(let text):
                    AssistantTextBlock(text: text)
                case .toolUse(let id, let name, let inputJSON):
                    ToolCallRow(
                        id: id,
                        name: name,
                        inputJSON: inputJSON,
                        result: toolResults[id]
                    )
                case .toolResult:
                    EmptyView()
                }
            }
            if !copyableText.isEmpty {
                CopyMessageButton(text: copyableText)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct AssistantTextBlock: View {
    let text: String

    var body: some View {
        MarkdownText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

private struct ReasoningBlock: View {
    let text: String
    let isComplete: Bool
    @State private var expanded = false

    private var firstLine: String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    } else {
                        ThinkingDots()
                    }
                    Text(firstLine.isEmpty ? (isComplete ? L10n.string("Thought") : L10n.string("Thinking…")) : firstLine)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(isComplete ? AppTheme.Text.tertiaryColor : AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isComplete)
    }
}

private struct RedactedReasoningBlock: View {
    let data: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(L10n.string("Reasoning (redacted)"))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(verbatim: data)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ToolCallRow: View {
    let id: String
    let name: String
    let inputJSON: String
    let result: ToolRunResult?
    @State private var expanded = false

    private var isRunning: Bool { result == nil }
    private var statusIcon: String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }
    private var statusTint: Color {
        guard let result else { return AppTheme.Text.mutedColor }
        return result.isError ? .red.opacity(0.8) : AppTheme.Text.tertiaryColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(statusTint)
                    }
                    Text(name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRunning ? AppTheme.Text.tertiaryColor.opacity(0.7) : AppTheme.Text.secondaryColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    argsSection
                    if let result { resultSection(result) }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
                        )
                )
                .textSelection(.enabled)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var argsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("args")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(prettyPrinted(inputJSON))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func resultSection(_ r: ToolRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(r.isError ? "error" : "result")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(r.isError ? .red.opacity(0.8) : AppTheme.Text.mutedColor)
                if r.isError {
                    CopyButton(value: errorText(from: r))
                        .font(.system(size: 10))
                }
            }
            ForEach(Array(r.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let base64, _):
                    ToolResultImageView(base64: base64)
                }
            }
        }
    }

    private func errorText(from r: ToolRunResult) -> String {
        r.content.compactMap { block -> String? in
            if case .text(let s) = block { return s }
            return nil
        }.joined(separator: "\n")
    }

    private struct CopyButton: View {
        private static let feedbackDuration: Duration = .seconds(1.4)
        let value: String
        @State private var copied = false

        var body: some View {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .frame(width: 24, height: 24)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help(copied ? L10n.string("Copied") : L10n.string("Copy"))
        }

        private func copy() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: Self.feedbackDuration)
                copied = false
            }
        }
    }

    private func prettyPrinted(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: roundJSONForPrettyPrint(obj, toPlaces: 3),
                  options: [.prettyPrinted]
              ),
              let s = String(data: pretty, encoding: .utf8),
              !s.isEmpty, s != "{}" else {
            return "(no args)"
        }
        return s
    }
}

private struct ToolResultImageView: View {
    let base64: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(L10n.string("(image payload)"))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .task(id: base64) {
            guard image == nil else { return }
            let data = await Task.detached { Data(base64Encoded: base64) }.value
            if let data { image = NSImage(data: data) }
        }
    }
}

private func roundJSONForPrettyPrint(_ value: Any, toPlaces places: Int) -> Any {
    let multiplier = pow(10.0, Double(places))
    if let dict = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, val) in dict {
            result[key] = roundJSONForPrettyPrint(val, toPlaces: places)
        }
        return result
    } else if let array = value as? [Any] {
        return array.map { roundJSONForPrettyPrint($0, toPlaces: places) }
    } else if let num = value as? Double {
        return (num * multiplier).rounded() / multiplier
    } else if let num = value as? NSNumber, num.doubleValue != 0 || num.isEqual(to: 0) {
        let doubleValue = num.doubleValue
        if floor(doubleValue) == doubleValue {
            return num
        }
        return (doubleValue * multiplier).rounded() / multiplier
    }
    return value
}

private struct CopyMessageButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? L10n.string("Copied") : L10n.string("Copy"))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
                )
            }
            .buttonStyle(.plain)
            .help(L10n.string("Copy message"))
        }
    }
}

struct ToolRunResult {
    let content: [ToolResult.Block]
    let isError: Bool
}