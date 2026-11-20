import Foundation

struct HyperframesPlacementReceipt: Sendable, Codable, Equatable {
    var blockId: String
    var blockName: String
    var assetCount: Int
    var placedClipIds: [String]
    var trackIndex: Int
    var startFrame: Int
    var durationFrames: Int
    var motionPreset: String?
}

extension EditorViewModel {
    /// Installs a HyperFrames block into the project's media library. The block
    /// must be present in the local catalog mirror. Uses the same domain operation
    /// as `import_media` — one undo entry, same manifest/undo path, no second
    /// implementation of the install rules.
    func installHyperframesBlock(_ block: HyperframesBlock, into folderId: String? = nil) async throws -> MediaImportSummary {
        let mirrorBase = HyperframesCatalog.base
        let base: URL? = !mirrorBase.isEmpty ? URL(string: mirrorBase) : nil
        let resolvedAssets = block.assets.compactMap { assetPath -> URL? in
            if assetPath.hasPrefix("file://") { return URL(string: assetPath) }
            guard let base else { return nil }
            return HyperframesBlock.resolve(assetPath, base: base)
        }
        guard !resolvedAssets.isEmpty else {
            if mirrorBase.isEmpty {
                throw ToolError("Hyperframes catalog mirror not configured")
            }
            throw ToolError("HyperFrames block has no resolvable assets")
        }
        let resolvedFolderId = folderId ?? self.mediaPanelCurrentFolderId
        return try await importFinderItems(resolvedAssets, into: resolvedFolderId, finalize: true)
    }

    /// Installs a HyperFrames block into the project's media library AND places it onto
    /// the target visual track on the timeline with motion presets and compositing style
    /// as one atomic, undoable user action.
    @discardableResult
    func insertAndPlaceHyperframesBlock(
        blockId: String,
        folderId: String? = nil,
        trackIndex: Int? = nil,
        startFrame: Int? = nil,
        durationFrames: Int? = nil,
        motionPreset: MotionPreset? = nil,
        blendMode: BlendMode? = nil,
        opacity: Double? = nil,
        scale: Double? = nil
    ) async throws -> HyperframesPlacementReceipt {
        guard let block = HyperframesCatalog.shared.block(id: blockId) else {
            throw ToolError("Unknown HyperFrames block id: \(blockId)")
        }

        let mirrorBase = HyperframesCatalog.base
        let base: URL? = !mirrorBase.isEmpty ? URL(string: mirrorBase) : nil
        let resolvedAssets = block.assets.compactMap { assetPath -> URL? in
            if assetPath.hasPrefix("file://") { return URL(string: assetPath) }
            guard let base else { return nil }
            return HyperframesBlock.resolve(assetPath, base: base)
        }
        guard !resolvedAssets.isEmpty else {
            if mirrorBase.isEmpty {
                throw ToolError("Hyperframes catalog mirror not configured")
            }
            throw ToolError("HyperFrames block \(blockId) has no resolvable assets")
        }

        let resolvedStart = max(0, startFrame ?? currentFrame)
        var resolvedTrack = trackIndex
        var effectiveDuration = durationFrames ?? block.defaultDurationFrames
        var placedClipIds: [String] = []

        let resolvedFolderId = folderId ?? mediaPanelCurrentFolderId
        _ = try await importFinderItems(resolvedAssets, into: resolvedFolderId, finalize: false) { apply in
            let mediaBefore = self.mediaLibraryUndoSnapshot()
            let importedSummary = self.undo.withoutRegistration { apply() }
            guard importedSummary.assetCount != 0 || !importedSummary.assets.isEmpty else {
                return importedSummary
            }
            for asset in importedSummary.assets {
                _ = await self.finalizeImportedAsset(asset, batchManifestUpdate: true)
            }

            let timelineBefore = self.timeline

            let targetTrack: Int
            if let req = resolvedTrack {
                guard self.timeline.tracks.indices.contains(req) else {
                    throw ToolError("Invalid track index: \(req). Timeline has \(self.timeline.tracks.count) tracks.")
                }
                guard self.timeline.tracks[req].type != .audio else {
                    throw ToolError("Track \(req) is an audio track and cannot hold visual motion blocks.")
                }
                targetTrack = req
            } else {
                let estimatedDur = effectiveDuration ?? 30
                let neededRange = resolvedStart..<(resolvedStart + estimatedDur)
                let freeVideoTrack = self.timeline.tracks.enumerated().first { idx, track in
                    track.type == .video && !track.clips.contains { clip in
                        let clipRange = clip.startFrame..<clip.endFrame
                        return clipRange.overlaps(neededRange)
                    }
                }
                if let freeTrack = freeVideoTrack {
                    targetTrack = freeTrack.offset
                } else {
                    let insertionIdx = ClipPlacement.trackInsertionIndex(type: .video, requested: 0, tracks: self.timeline.tracks)
                    self.timeline.tracks.insert(Track(type: .video), at: insertionIdx)
                    targetTrack = insertionIdx
                }
            }
            resolvedTrack = targetTrack

            var cursor = resolvedStart
            var allPlacedIds: [String] = []
            for asset in importedSummary.assets {
                let dur = effectiveDuration ?? self.clipDurationFrames(for: asset, segment: nil)
                let placed = self.placeClip(
                    asset: asset,
                    trackIndex: targetTrack,
                    startFrame: cursor,
                    durationFrames: dur,
                    addLinkedAudio: false
                )
                allPlacedIds.append(contentsOf: placed)
                cursor += dur
            }

            guard !allPlacedIds.isEmpty else {
                throw ToolError("No clips could be placed on the timeline for block \(blockId).")
            }

            if effectiveDuration == nil, let firstPlaced = allPlacedIds.first, let c = self.clipFor(id: firstPlaced) {
                effectiveDuration = c.durationFrames
            }

            for ti in self.timeline.tracks.indices {
                for ci in self.timeline.tracks[ti].clips.indices {
                    let clipId = self.timeline.tracks[ti].clips[ci].id
                    guard allPlacedIds.contains(clipId) else { continue }
                    if let blendMode {
                        self.timeline.tracks[ti].clips[ci].blendMode = blendMode
                    }
                    if let opacity {
                        self.timeline.tracks[ti].clips[ci].opacity = max(0, min(1, opacity))
                    }
                    if let scale {
                        self.timeline.tracks[ti].clips[ci].transform.width *= scale
                        self.timeline.tracks[ti].clips[ci].transform.height *= scale
                    }
                    if let motionPreset {
                        let dur = self.timeline.tracks[ti].clips[ci].durationFrames
                        self.timeline.tracks[ti].clips[ci].applyMotionPreset(motionPreset, requestedDuration: min(dur, 15))
                    }
                }
            }

            placedClipIds = allPlacedIds
            let timelineAfter = self.timeline

            let actionName = "Place Motion Block"
            self.undo.perform(actionName) {
                self.undo.register(actionName, withTarget: self) { vm in
                    vm.restoreMediaLibraryUndoSnapshot(mediaBefore, actionName: actionName)
                }
                if timelineBefore != timelineAfter {
                    self.registerTimelineSwap(undoState: timelineBefore, redoState: timelineAfter, actionName: actionName)
                }
            }
            self.notifyTimelineChanged()
            return importedSummary
        }

        return HyperframesPlacementReceipt(
            blockId: block.id,
            blockName: block.name,
            assetCount: resolvedAssets.count,
            placedClipIds: placedClipIds,
            trackIndex: resolvedTrack ?? 0,
            startFrame: resolvedStart,
            durationFrames: effectiveDuration ?? 30,
            motionPreset: motionPreset?.rawValue
        )
    }
}
