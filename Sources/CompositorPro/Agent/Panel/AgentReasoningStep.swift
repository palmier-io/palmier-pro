import SwiftUI

enum AgentReasoningStep {
    /// The first non-empty line of a reasoning block, used as the compact status for that step.
    static func oneLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

/// A single reasoning step in the chat: a live "Thinking…" row while the model reasons, then a
/// one-line status once that step completes. The full reasoning text is never shown.
struct ReasoningStepRow: View {
    let text: String
    let isComplete: Bool

    var body: some View {
        if isComplete {
            completed
        } else {
            thinking
        }
    }

    private var completed: some View {
        let line = AgentReasoningStep.oneLine(text)
        let label = line.isEmpty ? L10n.string("Thought") : line
        return HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(verbatim: label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: line.isEmpty ? L10n.string("Thought") : "\(L10n.string("Reasoning")): \(line)"))
    }

    private var thinking: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ThinkingDots()
            Text(L10n.string("Thinking…"))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: L10n.string("Thinking…")))
    }
}