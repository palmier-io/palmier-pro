import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack(alignment: .topLeading) {
                // Fixed 16:9 container with letterboxing
                ZStack {
                    Rectangle().fill(Color.black)
                    thumbnailContent
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

                thumbnailBadges
            }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            )

            // Timeline indicator
            if isOnTimeline {
                Capsule()
                    .fill(Color(nsColor: asset.type.themeColor))
                    .frame(height: 2)
            }

            // Filename
            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            handleTap()
        }
    }

    private var thumbnailContent: some View {
        Group {
            if asset.isGenerating {
                GeneratingOverlay()
            } else if case .failed(let error) = asset.generationStatus {
                failedThumbnail(error: error)
            } else if let thumbnail = asset.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: asset.type.sfSymbolName)
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    @ViewBuilder
    private var thumbnailBadges: some View {
        if asset.isGenerated && !asset.isGenerating {
            sourceBadge
                .padding(4)
        }

        if showsDurationBadge {
            durationBadge
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(4)
        }
    }

    // MARK: - Badges

    private var sourceBadge: some View {
        Text("AI")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .glassEffect(.clear, in: .capsule)
    }

    private var durationBadge: some View {
        Text(formatDuration(asset.duration))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .glassEffect(.clear, in: .capsule)
    }

    private func failedThumbnail(error: String) -> some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.red.opacity(0.8))
            Text("Failed")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .help(error)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - State

    private var isSelected: Bool {
        editor.selectedMediaAssetIds.contains(asset.id)
    }

    private var showsDurationBadge: Bool {
        (asset.type == .video || asset.type == .audio) && asset.duration > 0
    }

    private var isOnTimeline: Bool {
        editor.timeline.tracks.contains { track in
            track.clips.contains { $0.mediaRef == asset.id }
        }
    }

    private func handleTap() {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)

        if shiftHeld {
            if editor.selectedMediaAssetIds.contains(asset.id) {
                editor.selectedMediaAssetIds.remove(asset.id)
            } else {
                editor.selectedMediaAssetIds.insert(asset.id)
            }
        } else {
            editor.selectedMediaAssetIds = [asset.id]
        }

        editor.openPreviewTab(for: asset)
    }
}
