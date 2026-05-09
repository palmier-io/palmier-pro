import SwiftUI

struct GenerationReferencesStrip: View {
    let generationInput: GenerationInput
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let slots = Self.slots(for: generationInput, in: editor.mediaAssets)
        if !slots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        thumbnail(label: slot.0, asset: slot.1)
                    }
                }
            }
        }
    }

    /// Returns true if any reference asset can be resolved against `assets`.
    static func hasResolvableReferences(_ gen: GenerationInput, in assets: [MediaAsset]) -> Bool {
        !slots(for: gen, in: assets).isEmpty
    }

    private static func slots(for gen: GenerationInput, in assets: [MediaAsset]) -> [(String, MediaAsset)] {
        let lookup: (String) -> MediaAsset? = { id in assets.first(where: { $0.id == id }) }
        let primaryLabels = primaryLabels(for: gen)
        let groups: [([String]?, (Int, Int) -> String)] = [
            (gen.imageURLAssetIds,       { i, _ in primaryLabels[safe: i] ?? "Reference" }),
            (gen.referenceImageAssetIds, numbered("Image Ref")),
            (gen.referenceVideoAssetIds, numbered("Video Ref")),
            (gen.referenceAudioAssetIds, numbered("Audio Ref")),
        ]
        return groups.flatMap { ids, label in
            let ids = ids ?? []
            return ids.enumerated().compactMap { i, id in
                lookup(id).map { (label(i, ids.count), $0) }
            }
        }
    }

    private static func primaryLabels(for gen: GenerationInput) -> [String] {
        guard case .video(let m) = ModelRegistry.byId[gen.model] else { return [] }
        if m.requiresSourceVideo { return m.supportsReferences ? ["Source", "Reference"] : ["Source"] }
        if m.supportsFirstFrame  { return m.supportsLastFrame  ? ["First Frame", "Last Frame"] : ["First Frame"] }
        return []
    }

    private static func numbered(_ base: String) -> (Int, Int) -> String {
        { i, total in total > 1 ? "\(base) \(i + 1)" : base }
    }

    private func thumbnail(label: String, asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Rectangle().fill(Color.black)
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.type.sfSymbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .frame(width: 72, height: 41)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .help("\(label) · \(asset.name)")
        .onTapGesture {
            editor.selectedClipIds.removeAll()
            editor.selectedFolderIds.removeAll()
            editor.selectedMediaAssetIds = [asset.id]
            editor.openPreviewTab(for: asset)
            editor.mediaPanelRevealAssetId = asset.id
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
