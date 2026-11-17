import AppKit
import SwiftUI

struct AgentMessageView: View {
    let message: AgentMessage
    let toolResults: [String: ToolRunResult]
    var showsHeader = true
    var onDisclosure: () -> Void = {}
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
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, AppTheme.Spacing.xs)
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
            HStack(alignment: .top, spacing: AppTheme.Spacing.zero) {
                Spacer(minLength: AppTheme.Spacing.xlXxl)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    HStack {
                        Text(L10n.string("You"))
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        CopyMessageButton(text: copyableText)
                            .opacity(isHovering ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
                    }
                    Text(verbatim: texts.joined(separator: "\n"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineSpacing(AppTheme.Spacing.xxs)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(AppTheme.Spacing.mdLg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                                .stroke(AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
                        )
                )
                .onHover { isHovering = $0 }
            }
        }
        // Tool-result user messages render merged into the preceding assistant row.
    }

    // Separate reasoning identities keep disclosure state stable as text blocks arrive.
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            if showsHeader {
                Label(L10n.string("Agent"), systemImage: "sparkles")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .padding(.bottom, AppTheme.Spacing.xs)
            }
            ForEach(renderedBlocks, id: \.key) { entry in
                let block = entry.block
                switch block {
                case .thinking(let text, let signature):
                    ReasoningBlock(text: text, isComplete: !signature.isEmpty, onDisclosure: onDisclosure)
                case .redactedThinking(let data):
                    RedactedReasoningBlock(data: data, onDisclosure: onDisclosure)
                case .openAIReasoning(let summary, _, _, _, let isComplete):
                    ReasoningBlock(text: summary, isComplete: isComplete, onDisclosure: onDisclosure)
                case .text(let text):
                    AssistantTextBlock(text: text)
                case .toolUse(let id, let name, let inputJSON):
                    ToolCallRow(
                        id: id,
                        name: name,
                        inputJSON: inputJSON,
                        result: toolResults[id],
                        onDisclosure: onDisclosure
                    )
                case .toolResult:
                    EmptyView()
                }
            }
            if !copyableText.isEmpty {
                CopyMessageButton(text: copyableText)
                    .opacity(isHovering ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovering)
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
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
    let onDisclosure: () -> Void
    @State private var expanded = false

    private var firstLine: String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button {
                if !expanded { onDisclosure() }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { expanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    if isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    } else {
                        ThinkingDots()
                    }
                    Text(firstLine.isEmpty ? (isComplete ? L10n.string("Thought") : L10n.string("Thinking…")) : firstLine)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular, design: .monospaced))
                        .foregroundStyle(isComplete ? AppTheme.Text.tertiaryColor : AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            if expanded {
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(AppTheme.Spacing.mdLg)
                }
                .frame(maxHeight: AppTheme.Chat.detailMaxHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isComplete)
    }
}

private struct RedactedReasoningBlock: View {
    let data: String
    let onDisclosure: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button {
                if !expanded { onDisclosure() }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { expanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: "lock.circle.fill")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(L10n.string("Reasoning (redacted)"))
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            if expanded {
                ScrollView {
                    Text(verbatim: data)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(AppTheme.Spacing.mdLg)
                }
                .frame(maxHeight: AppTheme.Chat.detailMaxHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
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
    let onDisclosure: () -> Void
    @State private var expanded = false

    private var isRunning: Bool { result == nil }
    private var statusIcon: String {
        guard let result else { return "circle.dotted" }
        return result.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }
    private var statusTint: Color {
        guard let result else { return AppTheme.Accent.primary }
        return result.isError ? AppTheme.Status.errorColor : AppTheme.Status.successColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            Button {
                if !expanded { onDisclosure() }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { expanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.md) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(statusTint)
                    }
                    Text(verbatim: name)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium, design: .monospaced))
                        .foregroundStyle(isRunning ? AppTheme.Text.tertiaryColor.opacity(AppTheme.Opacity.high) : AppTheme.Text.secondaryColor)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.surfaceColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
            )

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    argsSection
                    if let result { resultSection(result) }
                }
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.mdLg)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                        )
                )
                .textSelection(.enabled)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var argsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Arguments"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(verbatim: prettyPrinted(inputJSON))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func resultSection(_ r: ToolRunResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Text(r.isError ? L10n.string("Error") : L10n.string("Result"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(r.isError ? AppTheme.Status.errorColor : AppTheme.Text.mutedColor)
                if r.isError {
                    CopyButton(value: errorText(from: r))
                        .font(.system(size: AppTheme.FontSize.xs))
                }
            }
            ForEach(Array(r.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(verbatim: s)
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
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
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
            return L10n.string("No arguments")
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
                    .frame(maxHeight: AppTheme.Chat.imageMaxHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
            } else {
                Text(L10n.string("(image payload)"))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
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
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? L10n.string("Copied") : L10n.string("Copy"))
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
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
