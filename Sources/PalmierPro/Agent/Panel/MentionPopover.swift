import SwiftUI

extension MediaAsset {
    // Collapses spaces and hyphens so the inserted `@token` stays a single word.
    var mentionDisplayName: String {
        var result = ""
        var lastWasDash = false
        for ch in name {
            if ch == " " || ch == "-" {
                if !lastWasDash { result.append("-") }
                lastWasDash = true
            } else {
                result.append(ch)
                lastWasDash = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum MentionTab: CaseIterable, Hashable {
    case all, video, image, audio

    var label: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .image: "Image"
        case .audio: "Audio"
        }
    }

    var clipType: ClipType? {
        switch self {
        case .all: nil
        case .video: .video
        case .image: .image
        case .audio: .audio
        }
    }
}

/// Pure render. State lives on `AgentInputBox` so keyboard nav follows the focused TextEditor.
struct MentionPopover: View {
    let query: String
    let candidates: [MediaAsset]
    @Binding var highlightedIndex: Int
    @Binding var tab: MentionTab
    let scrollTick: Int
    let onPick: (MediaAsset) -> Void

    @State private var visibleIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: 0.5)
            contentArea
                .frame(height: 280)
        }
        .frame(width: 260)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    @ViewBuilder
    private var contentArea: some View {
        if candidates.isEmpty {
            Text(query.isEmpty ? "No \(tab.label.lowercased()) media" : "No matches for \"\(query)\"")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppTheme.Spacing.md)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, asset in
                            mentionRow(asset: asset, isHighlighted: index == highlightedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(asset) }
                                .onHover { hovering in if hovering { highlightedIndex = index } }
                                .id(asset.id)
                                .onScrollVisibilityChange(threshold: 0.95) { visible in
                                    if visible {
                                        visibleIDs.insert(asset.id)
                                    } else {
                                        visibleIDs.remove(asset.id)
                                    }
                                }
                        }
                    }
                }
                .onChange(of: scrollTick) { _, _ in
                    scrollHighlightIntoViewIfNeeded(proxy: proxy)
                }
                .onChange(of: candidates.map(\.id)) { _, ids in
                    visibleIDs.formIntersection(ids)
                }
            }
        }
    }

    private func scrollHighlightIntoViewIfNeeded(proxy: ScrollViewProxy) {
        guard candidates.indices.contains(highlightedIndex) else { return }
        let targetID = candidates[highlightedIndex].id
        if visibleIDs.contains(targetID) { return }

        let visibleIndices = visibleIDs.compactMap { id in
            candidates.firstIndex { $0.id == id }
        }
        let anchor: UnitPoint = (visibleIndices.max().map { highlightedIndex > $0 } ?? false)
            ? .bottom
            : .top

        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(targetID, anchor: anchor)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(MentionTab.allCases, id: \.self) { t in
                Text(t.label)
                    .font(.system(size: 10, weight: t == tab ? .semibold : .regular))
                    .foregroundStyle(t == tab ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        t == tab
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
            }
        }
        .padding(4)
    }

    private func mentionRow(asset: MediaAsset, isHighlighted: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Group {
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: asset.type.sfSymbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(width: 28, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.mentionDisplayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(asset.type.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, 4)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : .clear)
    }
}
