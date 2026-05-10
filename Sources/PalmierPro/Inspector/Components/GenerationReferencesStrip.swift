import SwiftUI

struct GenerationReferencesStrip: View {
    let generationInput: GenerationInput
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let slots = Self.slots(for: generationInput, in: editor.mediaAssets)
        if !slots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    ForEach(slots.indices, id: \.self) { i in
                        thumbnail(label: slots[i].0, asset: slots[i].1)
                    }
                }
            }
        }
    }

    static func hasResolvableReferences(_ gen: GenerationInput, in assets: [MediaAsset]) -> Bool {
        !slots(for: gen, in: assets).isEmpty
    }

    static func slots(for gen: GenerationInput, in assets: [MediaAsset]) -> [(String, MediaAsset)] {
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let primary = primaryLabels(for: gen)
        let groups: [(ids: [String]?, base: String, primary: [String])] = [
            (gen.imageURLAssetIds,       "Reference", primary),
            (gen.referenceImageAssetIds, "Image Ref", []),
            (gen.referenceVideoAssetIds, "Video Ref", []),
            (gen.referenceAudioAssetIds, "Audio Ref", []),
        ]
        return groups.flatMap { ids, base, primary -> [(String, MediaAsset)] in
            let ids = ids ?? []
            return ids.enumerated().compactMap { i, id in
                guard let asset = byId[id] else { return nil }
                if i < primary.count { return (primary[i], asset) }
                return (ids.count > 1 ? "\(base) \(i + 1)" : base, asset)
            }
        }
    }

    private static func primaryLabels(for gen: GenerationInput) -> [String] {
        guard case .video(let m) = ModelRegistry.byId[gen.model] else { return [] }
        if m.requiresSourceVideo { return m.supportsReferences ? ["Source", "Reference"] : ["Source"] }
        if m.supportsFirstFrame  { return m.supportsLastFrame  ? ["First Frame", "Last Frame"] : ["First Frame"] }
        return []
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
