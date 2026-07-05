import SwiftUI

// Prompt @-autocomplete for reference tags (Seedance/Kling/Grok reference mode).
extension GenerationView {

    var availableRefTags: [RefTag] {
        guard showsRefSections else { return [] }
        return ClipType.allCases.flatMap { type -> [RefTag] in
            let noun = tagNoun(for: type)
            return (0..<refCount(for: type)).map { i in
                RefTag(label: "\(noun)\(i + 1)", kindLabel: type.rawValue)
            }
        }
    }

    private var matchedRefTags: [RefTag] {
        let q = (refMentionQuery ?? "").lowercased()
        if q.isEmpty { return availableRefTags }
        return availableRefTags.filter { $0.label.lowercased().contains(q) }
    }

    var showMentionPicker: Bool {
        refMentionQuery != nil && !availableRefTags.isEmpty
    }

    var refMentionPopover: some View {
        let tags = matchedRefTags
        return VStack(alignment: .leading, spacing: 0) {
            if tags.isEmpty {
                Text("No matches")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("@\(tag.label)")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(tag.kindLabel)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .frame(minWidth: 160, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(index == highlightedMentionIndex ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { pickRefTag(tag) }
                    .onHover { hovering in if hovering { highlightedMentionIndex = index } }
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .frame(minWidth: 180)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    func updateRefMentionQuery(from text: String) {
        let newQuery: String? = {
            guard !availableRefTags.isEmpty else { return nil }
            guard let lastAt = text.lastIndex(of: "@") else { return nil }
            let after = text[text.index(after: lastAt)...]
            if after.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
            if lastAt > text.startIndex {
                let prev = text[text.index(before: lastAt)]
                if !prev.isWhitespace && !prev.isNewline { return nil }
            }
            return String(after)
        }()
        guard newQuery != refMentionQuery else { return }
        refMentionQuery = newQuery
        highlightedMentionIndex = 0
    }

    func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        guard showMentionPicker else { return .ignored }
        let tags = matchedRefTags
        switch press.key {
        case .upArrow:
            guard !tags.isEmpty else { return .handled }
            highlightedMentionIndex = max(0, highlightedMentionIndex - 1)
            return .handled
        case .downArrow:
            guard !tags.isEmpty else { return .handled }
            highlightedMentionIndex = min(tags.count - 1, highlightedMentionIndex + 1)
            return .handled
        case .return:
            if tags.indices.contains(highlightedMentionIndex) {
                pickRefTag(tags[highlightedMentionIndex])
                return .handled
            }
            return .ignored
        case .escape:
            refMentionQuery = nil
            return .handled
        default:
            return .ignored
        }
    }

    private func pickRefTag(_ tag: RefTag) {
        if let lastAt = prompt.lastIndex(of: "@") {
            let prefix = prompt[..<lastAt]
            prompt = String(prefix) + "@\(tag.label) "
        } else {
            prompt += "@\(tag.label) "
        }
        refMentionQuery = nil
        highlightedMentionIndex = 0
    }
}
