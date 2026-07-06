import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Folder-drag string contract

extension MediaTab {
    static let folderDragScheme = "palmier-folder://"
    static let assetDragScheme = "palmier-asset://"
    static let timelineDragScheme = "palmier-timeline://"

    static func folderDragString(forFolderId id: String) -> String {
        folderDragScheme + id
    }

    static func folderId(fromDragString line: String) -> String? {
        line.hasPrefix(folderDragScheme) ? String(line.dropFirst(folderDragScheme.count)) : nil
    }

    static func timelineDragString(forTimelineId id: String) -> String {
        timelineDragScheme + id
    }

    static func timelineId(fromDragString line: String) -> String? {
        line.hasPrefix(timelineDragScheme) ? String(line.dropFirst(timelineDragScheme.count)) : nil
    }

    static func assetDragString(forAssetId id: String) -> String {
        assetDragScheme + id
    }

    /// A search "moment": `palmier-asset://<id>#<start>-<end>` in source seconds
    static func assetDragString(forAssetId id: String, segment: ClosedRange<Double>) -> String {
        assetDragScheme + id + String(format: "#%.3f-%.3f", segment.lowerBound, segment.upperBound)
    }

    static func assetId(fromDragString line: String) -> String? {
        guard line.hasPrefix(assetDragScheme) else { return nil }
        return String(line.dropFirst(assetDragScheme.count).prefix(while: { $0 != "#" }))
    }

    static func assetSegment(fromDragString line: String) -> ClosedRange<Double>? {
        guard line.hasPrefix(assetDragScheme), let hash = line.firstIndex(of: "#") else { return nil }
        let parts = line[line.index(after: hash)...].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Double(parts[0]), let end = Double(parts[1]),
              start >= 0, end > start else { return nil }
        return start...end
    }
}

// MARK: - Drag payload + preview (asset → timeline / folder)

extension MediaTab {
    func dragPayload(for asset: MediaAsset) -> String {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            return selectedMediaAssetsInOrder
                .map { Self.assetDragString(forAssetId: $0.id) }
                .joined(separator: "\n")
        }
        return Self.assetDragString(forAssetId: asset.id)
    }

    @ViewBuilder
    func dragPreview(for asset: MediaAsset) -> some View {
        let count = editor.selectedMediaAssetIds.contains(asset.id) ? editor.selectedMediaAssetIds.count : 1
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = asset.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: asset.type.sfSymbolName)
                            .font(.title2)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(width: 80, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.medium)
            )
            .shadow(color: .black.opacity(AppTheme.Opacity.medium), radius: 4, y: 2)

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(Capsule().fill(AppTheme.Accent.primary))
                    .offset(x: AppTheme.Spacing.xs, y: -AppTheme.Spacing.xs)
            }
        }
        .padding(.top, AppTheme.Spacing.xs)
        .padding(.trailing, AppTheme.Spacing.xs)
    }
}

// MARK: - Drop handlers (folder tile, breadcrumb, panel-level Finder drop)

extension MediaTab {
    @MainActor
    func handlePanelFinderDrop(urls: [URL]) {
        Task { @MainActor in
            await Self.handlePanelFinderDrop(urls: urls, into: currentFolderId, editor: editor)
        }
    }

    @MainActor
    static func handlePanelFinderDrop(urls: [URL], into destFolderId: String?, editor: EditorViewModel) async {
        await editor.importFinderItems(urls, into: destFolderId)
    }

    func handleProviderDrop(_ providers: [NSItemProvider], into destFolderId: String?) {
        for provider in providers {
            // Finder drops: file URL.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        await Self.handlePanelFinderDrop(urls: [url], into: destFolderId, editor: editor)
                    }
                }
                continue
            }
            // In-panel drags: folder sentinel + asset URLs from .draggable(String).
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let text = obj as? String else { return }
                    Task { @MainActor in
                        Self.resolveTextDrop(text, into: destFolderId, editor: editor)
                    }
                }
            }
        }
    }

    static func clipboardHasImportableMedia(pasteboard pb: NSPasteboard = .general) -> Bool {
        let types = pb.types ?? []
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

    @MainActor
    func handleClipboardPaste() {
        Task { @MainActor in
            await Self.handleClipboardPaste(pasteboard: .general, into: currentFolderId, editor: editor)
        }
    }

    @MainActor
    static func handleClipboardPaste(pasteboard pb: NSPasteboard, into destFolderId: String?, editor: EditorViewModel) async {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            await handlePanelFinderDrop(urls: urls, into: destFolderId, editor: editor)
            return
        }
        for (type, ext): (NSPasteboard.PasteboardType, String) in [(.png, "png"), (.tiff, "tiff")] {
            guard let data = pb.data(forType: type),
                  let asset = await editor.importPastedImageData(data, fileExtension: ext) else { continue }
            if let folderId = destFolderId {
                editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
            }
            return
        }
    }

    @MainActor
    static func resolveTextDrop(_ text: String, into destFolderId: String?, editor: EditorViewModel) {
        var assetIds: Set<String> = []
        var folderIds: Set<String> = []
        var timelineIds: Set<String> = []
        for line in text.split(separator: "\n").map(String.init) where !line.isEmpty {
            if let folderId = folderId(fromDragString: line) {
                folderIds.insert(folderId)
            } else if let timelineId = timelineId(fromDragString: line),
                      editor.timeline(for: timelineId) != nil {
                timelineIds.insert(timelineId)
            } else if let id = assetId(fromDragString: line),
                      editor.mediaAssets.contains(where: { $0.id == id }) {
                assetIds.insert(id)
            }
        }
        if !assetIds.isEmpty {
            editor.moveAssetsToFolder(assetIds: assetIds, folderId: destFolderId)
        }
        if !folderIds.isEmpty {
            editor.moveFoldersToFolder(folderIds: folderIds, parentFolderId: destFolderId)
        }
        if !timelineIds.isEmpty {
            editor.moveTimelinesToFolder(timelineIds: timelineIds, folderId: destFolderId)
        }
    }
}
