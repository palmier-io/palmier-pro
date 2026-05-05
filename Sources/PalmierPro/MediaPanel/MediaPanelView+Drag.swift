import SwiftUI
import UniformTypeIdentifiers

// MARK: - Folder-drag string contract

extension MediaPanelView {
    static let folderDragScheme = "palmier-folder://"

    static func folderDragString(forFolderId id: String) -> String {
        folderDragScheme + id
    }

    static func folderId(fromDragString line: String) -> String? {
        line.hasPrefix(folderDragScheme) ? String(line.dropFirst(folderDragScheme.count)) : nil
    }
}

// MARK: - Drag payload + preview (asset → timeline / folder)

extension MediaPanelView {
    func dragPayload(for asset: MediaAsset) -> String {
        if editor.selectedMediaAssetIds.contains(asset.id) {
            return selectedMediaAssetsInOrder.map(\.url.absoluteString).joined(separator: "\n")
        }
        return asset.url.absoluteString
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
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 4, y: -4)
            }
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }
}

// MARK: - Drop handlers (folder tile, breadcrumb, panel-level Finder drop)

extension MediaPanelView {
    /// Resolves three cases: folder drag, in-panel asset drag, Finder file drop.
    func handleProviderDrop(_ providers: [NSItemProvider], into destFolderId: String?) {
        for provider in providers {
            // Text covers folder sentinel + asset URLs from .draggable(String).
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let text = obj as? String else { return }
                    Task { @MainActor in resolveTextDrop(text, into: destFolderId) }
                }
                continue
            }
            // Fall back to file URL (Finder drops).
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let asset = editor.addMediaAsset(from: url), destFolderId != nil {
                            editor.moveAssetsToFolder(assetIds: [asset.id], folderId: destFolderId)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func resolveTextDrop(_ text: String, into destFolderId: String?) {
        var assetIds: Set<String> = []
        var folderIds: Set<String> = []
        for line in text.split(separator: "\n").map(String.init) where !line.isEmpty {
            if let folderId = Self.folderId(fromDragString: line) {
                folderIds.insert(folderId)
            } else if let asset = editor.mediaAssets.first(where: { $0.url.absoluteString == line }) {
                assetIds.insert(asset.id)
            }
        }
        if !assetIds.isEmpty {
            editor.moveAssetsToFolder(assetIds: assetIds, folderId: destFolderId)
        }
        if !folderIds.isEmpty {
            editor.moveFoldersToFolder(folderIds: folderIds, parentFolderId: destFolderId)
        }
    }
}
