import Foundation

@MainActor
extension Array where Element == MediaAsset {
    func sortedByGenerationDate() -> [MediaAsset] {
        sorted {
            ($0.generationInput?.createdAt ?? .distantPast)
                < ($1.generationInput?.createdAt ?? .distantPast)
        }
    }
}

extension EditorViewModel {

    func stackRootId(for asset: MediaAsset) -> String {
        asset.parentAssetId ?? asset.id
    }

    func stackRootId(forAssetId id: String) -> String? {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return nil }
        return stackRootId(for: asset)
    }

    /// Includes the root itself plus every variant pointing at it.
    func variants(ofStackRootId rootId: String) -> [MediaAsset] {
        mediaAssets.filter { $0.id == rootId || $0.parentAssetId == rootId }
    }

    func variantCount(ofStackRootId rootId: String) -> Int {
        variants(ofStackRootId: rootId).count
    }

    /// Members of this stack currently referenced by any timeline clip.
    func timelineVariantIds(forStackRootId rootId: String) -> Set<String> {
        let memberIds = Set(variants(ofStackRootId: rootId).map(\.id))
        var ids: Set<String> = []
        for track in timeline.tracks {
            for clip in track.clips where memberIds.contains(clip.mediaRef) {
                ids.insert(clip.mediaRef)
            }
        }
        return ids
    }

    /// Cover thumbnail rule: the variant on the timeline if exactly one is in
    /// use, otherwise the newest non-failed variant, falling back to the root.
    func coverVariant(forStackRootId rootId: String) -> MediaAsset? {
        let members = variants(ofStackRootId: rootId)
        guard let root = members.first(where: { $0.id == rootId }) else { return nil }
        let timelineIds = timelineVariantIds(forStackRootId: rootId)
        if timelineIds.count == 1,
           let id = timelineIds.first,
           let asset = members.first(where: { $0.id == id }) {
            return asset
        }
        return newestPresentableVariant(in: members) ?? root
    }

    /// Rewrite every timeline clip in this stack to point at `variantId`.
    func retargetStack(rootId: String, to variantId: String) {
        guard let root = mediaAssets.first(where: { $0.id == rootId }),
              let target = mediaAssets.first(where: { $0.id == variantId }),
              target.type == root.type,
              target.id == rootId || target.parentAssetId == rootId else { return }

        let memberIds = Set(variants(ofStackRootId: rootId).map(\.id))
        var changes: [(trackIndex: Int, clipIndex: Int, oldRef: String)] = []
        for (trackIndex, track) in timeline.tracks.enumerated() {
            for (clipIndex, clip) in track.clips.enumerated()
            where memberIds.contains(clip.mediaRef) && clip.mediaRef != variantId {
                changes.append((trackIndex, clipIndex, clip.mediaRef))
            }
        }
        guard !changes.isEmpty else { return }

        let undoRefs = changes.map { (trackIndex: $0.trackIndex, clipIndex: $0.clipIndex, ref: $0.oldRef) }
        let redoRefs = changes.map { (trackIndex: $0.trackIndex, clipIndex: $0.clipIndex, ref: variantId) }
        applyStackRefs(redoRefs)
        registerStackRetargetSwap(undoRefs: undoRefs, redoRefs: redoRefs)
        notifyTimelineChanged()
    }

    private func newestPresentableVariant(in members: [MediaAsset]) -> MediaAsset? {
        members
            .filter {
                if case .failed = $0.generationStatus { return false }
                return true
            }
            .sortedByGenerationDate()
            .last
    }

    /// Shared write path so apply and undo go through the same bounds-checked mutation.
    private func applyStackRefs(_ refs: [(trackIndex: Int, clipIndex: Int, ref: String)]) {
        for ref in refs {
            guard timeline.tracks.indices.contains(ref.trackIndex),
                  timeline.tracks[ref.trackIndex].clips.indices.contains(ref.clipIndex) else { continue }
            timeline.tracks[ref.trackIndex].clips[ref.clipIndex].mediaRef = ref.ref
        }
    }

    /// Swap-undo: each fire re-registers the inverse so undo↔redo cycle correctly.
    private func registerStackRetargetSwap(
        undoRefs: [(trackIndex: Int, clipIndex: Int, ref: String)],
        redoRefs: [(trackIndex: Int, clipIndex: Int, ref: String)]
    ) {
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.applyStackRefs(undoRefs)
            vm.registerStackRetargetSwap(undoRefs: redoRefs, redoRefs: undoRefs)
            vm.notifyTimelineChanged()
        }
        undoManager?.setActionName("Use Variant")
    }

    // MARK: - Deletion promotion

    struct StackPromotion {
        let newRoot: String
        let siblings: [String]
    }

    /// For each deleted root with surviving children, pick the oldest survivor
    /// as the new root.
    func planStackPromotions(forDeletedIds deletedSet: Set<String>) -> [StackPromotion] {
        var promotions: [StackPromotion] = []
        for deletedId in deletedSet {
            guard let asset = mediaAssets.first(where: { $0.id == deletedId }),
                  asset.parentAssetId == nil else { continue }
            let survivors = mediaAssets
                .filter { $0.parentAssetId == deletedId && !deletedSet.contains($0.id) }
                .sortedByGenerationDate()
            guard let newRoot = survivors.first else { continue }
            promotions.append(StackPromotion(
                newRoot: newRoot.id,
                siblings: Array(survivors.dropFirst().map(\.id))
            ))
        }
        return promotions
    }

    func applyStackPromotions(_ promotions: [StackPromotion]) {
        for promo in promotions {
            setParentAssetId(nil, forAssetId: promo.newRoot)
            for siblingId in promo.siblings {
                setParentAssetId(promo.newRoot, forAssetId: siblingId)
            }
        }
    }

    private func setParentAssetId(_ parent: String?, forAssetId id: String) {
        if let idx = mediaAssets.firstIndex(where: { $0.id == id }) {
            mediaAssets[idx].parentAssetId = parent
        }
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].parentAssetId = parent
        }
    }
}
