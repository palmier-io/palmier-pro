import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) var editor
    @FocusState private var isRenaming: Bool
    @State private var renameDraft = ""
    @State private var isHovering = false

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
            .overlay(alignment: .topTrailing) { hoverActions }
            .overlay(alignment: .bottomTrailing) { durationOverlay }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }

            // Timeline indicator
            if isOnTimeline {
                Capsule()
                    .fill(Color(nsColor: asset.type.themeColor))
                    .frame(height: 2)
            }

            // Filename
            if isRenaming {
                TextField("Name", text: $renameDraft, onCommit: commitRename)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isRenaming)
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
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            handleTap()
        }
        .onChange(of: isRenaming) { _, focused in
            if !focused { commitRename() }
        }
        .contextMenu { contextMenuItems }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        let ids = contextTargetIds
        Button("Reveal in Finder") { revealInFinder(ids: ids) }
        Button("Copy Path") { copyPaths(ids: ids) }
        Divider()
        Button("Delete", role: .destructive) { deleteAssets(ids: ids) }
    }

    /// Scope for a context-menu action: the full selection when the
    /// right-clicked asset is part of it, otherwise just this asset.
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
    }

    @ViewBuilder
    private var durationOverlay: some View {
        if showsDurationBadge {
            durationBadge.padding(4)
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovering && !asset.isGenerating {
            Button { editor.agentService.attachMention(for: asset) } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .background(.black.opacity(0.55), in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            .padding(4)
            .transition(.opacity)
            .help("Add to chat")
        }
    }

    // MARK: - Badges

    private var sourceBadge: some View {
        Text("AI")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AppTheme.aiGradient)
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

    private func beginRename() {
        renameDraft = asset.name
        isRenaming = true
    }

    private func commitRename() {
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
        }

        editor.openPreviewTab(for: asset)
    }
}
