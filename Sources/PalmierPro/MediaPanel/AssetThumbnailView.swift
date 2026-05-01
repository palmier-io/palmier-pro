import SwiftUI

struct AssetThumbnailView: View {
    enum StackContext: Equatable {
        case root(variantCount: Int, isExpanded: Bool)
        case variant(index: Int, total: Int)

        var isExpanded: Bool {
            if case .root(_, let exp) = self { return exp }
            return false
        }

        var variantCount: Int {
            switch self {
            case .root(let n, _): return n
            case .variant(_, let total): return total
            }
        }
    }

    let asset: MediaAsset
    var coverAsset: MediaAsset
    var stackContext: StackContext = .root(variantCount: 1, isExpanded: false)
    var onToggleExpand: (() -> Void)? = nil
    var onUseVariantInTimeline: (() -> Void)? = nil
    var onGroupAsStack: (() -> Void)? = nil
    var onRemoveFromStack: (() -> Void)? = nil

    @Environment(EditorViewModel.self) var editor
    @State private var isRenaming = false
    @FocusState private var isRenameFieldFocused: Bool
    @State private var renameDraft = ""
    @State private var isHovering = false

    private var isStackRoot: Bool {
        if case .root = stackContext { return true } else { return false }
    }
    private var hasVariants: Bool {
        stackContext.variantCount > 1
    }

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
                    Text(displayName)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                        .onTapGesture(count: 2) { beginRename() }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isRenaming ? Color.white.opacity(0.08) : .clear)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            handleTap()
        }
        .contextMenu { contextMenuItems }
    }

    private var displayName: String {
        switch stackContext {
        case .root: return asset.name
        case .variant(let i, _): return "v\(i) · \(asset.name)"
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        let ids = contextTargetIds
        if let onUseVariantInTimeline {
            Button("Use This Variant", action: onUseVariantInTimeline)
            Divider()
        }
        if let onGroupAsStack {
            Button("Group as Stack", action: onGroupAsStack)
        }
        if let onRemoveFromStack {
            Button("Remove from Stack", action: onRemoveFromStack)
        }
        if onGroupAsStack != nil || onRemoveFromStack != nil {
            Divider()
        }
        if let onToggleExpand, hasVariants {
            Button(stackContext.isExpanded ? "Collapse Stack" : "Expand Stack", action: onToggleExpand)
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
            if coverAsset.isGenerating {
                GeneratingOverlay()
            } else if case .failed(let error) = coverAsset.generationStatus {
                failedThumbnail(error: error)
            } else if let thumbnail = coverAsset.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: coverAsset.type.sfSymbolName)
                    .font(.system(size: 20))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    @ViewBuilder
    private var thumbnailBadges: some View {
        HStack(spacing: 4) {
            if coverAsset.isGenerated && !coverAsset.isGenerating {
                sourceBadge
            }
            if hasVariants, isStackRoot {
                stackCountPill
            }
            if case .variant(let i, _) = stackContext {
                variantOrdinalPill(index: i)
            }
        }
        .padding(4)
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

    private var stackCountPill: some View {
        Button {
            onToggleExpand?()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: stackContext.isExpanded ? "chevron.up" : "square.stack.3d.up.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text("\(stackContext.variantCount)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.black.opacity(0.55))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .hoverHighlight(cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(stackContext.isExpanded ? "Collapse stack" : "Show \(stackContext.variantCount) variants")
    }

    private func variantOrdinalPill(index: Int) -> some View {
        Text("v\(index)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .glassEffect(.clear, in: .capsule)
    }

    private var durationBadge: some View {
        Text(formatDuration(coverAsset.duration))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .glassEffect(.clear, in: .capsule)
    }

    private func failedThumbnail(error: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red.opacity(0.8))
            Text("Failed")
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(error)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.tail)
                .padding(.horizontal, AppTheme.Spacing.xs)
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
        (coverAsset.type == .video || coverAsset.type == .audio) && coverAsset.duration > 0
    }

    private var isOnTimeline: Bool {
        let isStackRowTile: Bool = {
            if case .root(let n, _) = stackContext { return n > 1 }
            return false
        }()
        if isStackRowTile {
            let memberIds = Set(editor.variants(ofStackRootId: asset.id).map(\.id))
            return editor.timeline.tracks.contains { track in
                track.clips.contains { memberIds.contains($0.mediaRef) }
            }
        }
        return editor.timeline.tracks.contains { track in
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
        }

        editor.openPreviewTab(for: coverAsset)
    }
}
