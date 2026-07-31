import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset
    var onMoveToFolderMenu: AnyView? = nil

    @Environment(EditorViewModel.self) var editor
    @State private var isRenaming = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(AppTheme.MediaOverlay.backgroundColor)
                thumbnailContent
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(alignment: .topLeading) { thumbnailBadges }
            .overlay(alignment: .topTrailing) { hoverActions }
            .overlay(alignment: .bottomTrailing) { durationOverlay }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }

            if isOnTimeline {
                Capsule()
                    .fill(Color(nsColor: asset.type.themeColor))
                    .frame(height: 2)
            }

            ZStack(alignment: .leading) {
                if isRenaming {
                    InlineRenameField(
                        originalName: asset.name,
                        placeholder: L10n.string("Name"),
                        font: .system(size: AppTheme.FontSize.xs),
                        onCommit: { name in
                            editor.renameMediaAsset(id: asset.id, name: name)
                            isRenaming = false
                        },
                        onCancel: { isRenaming = false }
                    )
                } else {
                    Text(asset.name)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                        .onTapGesture(count: 2) { beginRename() }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isRenaming ? AppTheme.Interaction.fill(AppTheme.Opacity.faint) : .clear)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            handleTap()
        }
        .contextMenu { contextMenuItems }
        .opacity(isSwapDimmed ? AppTheme.Opacity.muted : 1)
        .allowsHitTesting(!isSwapDimmed)
        .task(id: "\(asset.id)|\(asset.url.path)|\(asset.generationStatus.serialized)|\(isMissing)") {
            guard case .none = asset.generationStatus, !isMissing else { return }
            await asset.loadLibraryThumbnail()
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        let ids = contextTargetIds
        if let onMoveToFolderMenu {
            onMoveToFolderMenu
            Divider()
        }
        if ids.count == 1, ids.first == asset.id {
            if isMissing {
                Button(L10n.string("Relink…")) { relinkFile() }
                Divider()
            }
            Button(L10n.string("Rename")) { beginRename() }
            AIEditMenu(asset: asset)
            Divider()
        }
        Button(L10n.string("Reveal in Finder")) { revealInFinder(ids: ids) }
        Button(L10n.string("Copy Path")) { copyPaths(ids: ids) }
        Divider()
        Button(L10n.string("Delete"), role: .destructive) {
            editor.deleteMediaPanelItems(targeting: asset.id)
        }
    }

    private var contextTargetIds: [String] {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            return editor.mediaAssets
                .filter { editor.selectedMediaAssetIds.contains($0.id) }
                .map(\.id)
        }
        return [asset.id]
    }

    private func relinkFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose the source file for \"\(asset.name)\"")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.relinkAsset(id: asset.id, to: url)
        }
    }

    private func revealInFinder(ids: [String]) {
        let urls = editor.mediaAssets
            .filter { ids.contains($0.id) }
            .map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyPaths(ids: [String]) {
        let paths = editor.mediaAssets
            .filter { ids.contains($0.id) }
            .map(\.url.path)
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private var thumbnailContent: some View {
        Group {
            if asset.isGenerating {
                ZStack {
                    if let image = generatingReferenceImage {
                        Color.clear
                            .overlay { Image(nsImage: image).resizable().scaledToFill().blur(radius: 12) }
                            .clipped()
                        AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)
                    }
                    GeneratingOverlay(label: asset.generatingLabel)
                }
                .clipped()
            } else if case .failed(let error) = asset.generationStatus {
                failedThumbnail(error: error)
            } else if isMissing {
                missingThumbnail
            } else if let thumbnail = asset.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: asset.type.sfSymbolName)
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
            }
        }
    }

    private var generatingReferenceImage: NSImage? {
        guard let input = asset.generationInput else { return nil }
        let refIds = (input.imageURLAssetIds ?? []) + (input.referenceImageAssetIds ?? [])
        for id in refIds {
            guard let ref = editor.mediaAssets.first(where: { $0.id == id }), ref.type == .image else { continue }
            if let image = ref.thumbnail ?? NSImage(contentsOf: ref.url) {
                return image
            }
        }
        return nil
    }

    @ViewBuilder
    private var thumbnailBadges: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if asset.isGenerated && !asset.isGenerating {
                sourceBadge
            }
        }
        .padding(AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var durationOverlay: some View {
        if showsDurationBadge {
            durationBadge
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering && !asset.isGenerating && !isSwapPickMode {
            Button { editor.agentService.attachMention(for: asset) } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.MediaOverlay.primaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            }
            .buttonStyle(.plain)
            .background(AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong), in: .circle)
            .overlay(Circle().strokeBorder(
                AppTheme.MediaOverlay.primaryColor.opacity(AppTheme.Opacity.muted),
                lineWidth: AppTheme.BorderWidth.hairline
            ))
            .padding(AppTheme.Spacing.xs)
            .transition(.opacity)
            .help(L10n.string("Add to chat"))
        }
    }

    private var sourceBadge: some View {
        Text(verbatim: "AI")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .foregroundStyle(AppTheme.MediaOverlay.aiGradient)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.prominent), in: .capsule)
    }

    private var durationBadge: some View {
        Text(formatDuration(asset.duration))
            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            .monospacedDigit()
            .tileBadge()
    }

    private func failedThumbnail(error: String) -> some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.mdLg))
                .foregroundStyle(.red.opacity(AppTheme.Opacity.prominent))
            Text(L10n.string("Failed"))
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.MediaOverlay.secondaryColor)
            Text(error)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.tail)
                .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .help(error)
    }

    private var missingThumbnail: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.mdLg))
                .foregroundStyle(AppTheme.MediaOverlay.errorColor)
            Text(L10n.string("Media Offline"))
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.MediaOverlay.secondaryColor)
        }
        .help(L10n.string("Palmier couldn't load this source file. It may be missing, on an ejected drive, or unreadable."))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var isSelected: Bool {
        editor.selectedMediaAssetIds.contains(asset.id)
    }

    private var isSwapPickMode: Bool {
        editor.pendingSwapClipId != nil
    }

    private var isSwapCompatible: Bool {
        editor.isAssetCompatibleWithPendingSwap(asset)
    }

    private var isSwapDimmed: Bool {
        isSwapPickMode && !isSwapCompatible
    }

    private var isSwapPickHighlighted: Bool {
        isSwapPickMode && isSwapCompatible && isHovering
    }

    private var isMissing: Bool {
        // Generating/downloading/failed assets have their own states — not "offline".
        guard case .none = asset.generationStatus else { return false }
        return editor.isMediaOffline(asset.id)
    }

    private var borderColor: Color {
        if isMissing { return AppTheme.Status.errorColor }
        if isSwapPickMode { return isSwapPickHighlighted ? AppTheme.Accent.primary : .clear }
        return isSelected ? AppTheme.Accent.primary : .clear
    }

    private var borderWidth: CGFloat {
        if isSwapPickMode { return isSwapPickHighlighted ? AppTheme.BorderWidth.thick : 0 }
        return (isMissing || isSelected) ? AppTheme.BorderWidth.thick : 0
    }

    private var showsDurationBadge: Bool {
        (asset.type == .video || asset.type == .audio) && asset.duration > 0
    }

    private var isOnTimeline: Bool {
        editor.timeline.tracks.contains { track in
            track.clips.contains { $0.mediaRef == asset.id }
        }
    }

    private func beginRename() {
        isRenaming = true
    }

    private func handleTap() {
        if isSwapPickMode {
            editor.completeMediaSwap(with: asset)
            return
        }

        let mode = MediaPanelSelectionMode(modifierFlags: NSEvent.modifierFlags)
        editor.selectMediaPanelItem(asset.id, mode: mode)
    }
}
