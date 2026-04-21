import SwiftUI

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

/// Candidates + highlight index + tab live on `AgentInputBox` so keyboard nav
/// can run off the focused TextEditor; this view is pure render.
struct MentionPopover: View {
    let query: String
    let candidates: [MediaAsset]
    @Binding var highlightedIndex: Int
    @Binding var tab: MentionTab
    let onPick: (MediaAsset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: 0.5)
            if candidates.isEmpty {
                Text(query.isEmpty ? "No \(tab.label.lowercased()) media" : "No matches for \"\(query)\"")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, asset in
                    mentionRow(asset: asset, isHighlighted: index == highlightedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(asset) }
                        .onHover { hovering in if hovering { highlightedIndex = index } }
                }
            }
        }
        .frame(width: 260)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
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
                Text(asset.name)
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
