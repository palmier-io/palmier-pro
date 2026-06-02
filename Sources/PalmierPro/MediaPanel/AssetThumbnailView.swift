import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset
    var onMoveToFolderMenu: AnyView? = nil

    @Environment(EditorViewModel.self) var editor
    @State private var isRenaming = false
    @FocusState private var isRenameFieldFocused: Bool
    @State private var renameDraft = ""
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(Color.black)
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
                    TextField("Name", text: $renameDraft)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isRenameFieldFocused)
                        .onSubmit { commitRename() }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                        .onExitCommand { isRenaming = false }
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
                    .fill(isRenaming ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            handleTap()
        }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        let ids = contextTargetIds
        if let onMoveToFolderMenu {
            onMoveToFolderMenu
            Divider()
        }
        if ids.count == 1, ids.first == asset.id {
            Button("Rename") { beginRename() }
        }
        Button("Reveal in Finder") { revealInFinder(ids: ids) }
        Button("Copy Path") { copyPaths(ids: ids) }
        Divider()
        Button("Delete", role: .destructive) { deleteAssets(ids: ids) }
    }

    private var contextTargetIds: [String] {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            return editor.mediaAssets
                .filter { editor.selectedMediaAssetIds.contains($0.id) }
                .map(\.id)
        }
        return [asset.id]
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

    private func deleteAssets(ids: [String]) {
        editor.selectedMediaAssetIds = Set(ids)
        editor.deleteSelectedMediaAssets()
    }

    private var thumbnailContent: some View {
        Group {
            if asset.isGenerating {
                GeneratingOverlay(label: asset.generatingLabel)
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
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
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
            durationBadge.padding(AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering && !asset.isGenerating {
            Button { editor.agentService.attachMention(for: asset) } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
            }
            .buttonStyle(.plain)
            .background(.black.opacity(AppTheme.Opacity.strong), in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline))
            .padding(AppTheme.Spacing.xs)
            .transition(.opacity)
            .help("Add to chat")
        }
    }

    private var sourceBadge: some View {
        Text("AI")
            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
            .foregroundStyle(AppTheme.aiGradient)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Color.black.opacity(AppTheme.Opacity.prominent), in: .capsule)
    }

    private var durationBadge: some View {
        Text(formatDuration(asset.duration))
            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(.ultraThinMaterial, in: .capsule)
    }

    private func failedThumbnail(error: String) -> some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.mdLg))
                .foregroundStyle(.red.opacity(AppTheme.Opacity.prominent))
            Text("Failed")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(error)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
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
                .foregroundStyle(AppTheme.Status.errorColor)
            Text("Media Missing")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .help("The source file for this media could not be found.")
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

    private var isMissing: Bool {
        // Generating/downloading/failed assets have their own states — not "missing".
        guard case .none = asset.generationStatus else { return false }
        return editor.mediaResolver.isMissing(for: asset.id)
    }

    private var borderColor: Color {
        if isMissing { return AppTheme.Status.errorColor }
        return isSelected ? AppTheme.Accent.primary : .clear
    }

    private var borderWidth: CGFloat {
        (isMissing || isSelected) ? AppTheme.BorderWidth.thick : 0
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
        renameDraft = asset.name
        isRenaming = true
        isRenameFieldFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != asset.name {
            editor.renameMediaAsset(id: asset.id, name: trimmed)
        }
        isRenaming = false
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
            editor.selectedFolderIds.removeAll()
        }

        editor.openPreviewTab(for: asset)
    }
}
