import Foundation

extension EditorViewModel {

    /// Proposes a timeline arrangement from creative direction and imported library media.
    func proposeEditPilotArrangement(
        direction: String,
        mediaRefs: [String]? = nil,
        musicMediaRef: String? = nil,
        targetDurationSeconds: Double? = nil,
        pacing: EditPilotPacing? = nil
    ) async throws -> EditPilotArrangement {
        let resolvedPacing = pacing ?? EditPilotPacing.infer(from: direction)
        let fps = Double(timeline.fps)

        // 1. Collect visual media candidates from the manifest and library assets.
        var candidateEntries: [MediaManifestEntry] = []
        if !mediaManifest.entries.isEmpty {
            candidateEntries = mediaManifest.entries.filter { $0.type == .video || $0.type == .image }
        } else {
            candidateEntries = mediaAssets.compactMap { asset -> MediaManifestEntry? in
                guard asset.type == .video || asset.type == .image else { return nil }
                return MediaManifestEntry(
                    id: asset.id,
                    name: asset.name,
                    type: asset.type,
                    source: .external(absolutePath: asset.url.path),
                    duration: asset.duration
                )
            }
        }

        // If specific mediaRefs are requested, filter and preserve order while deduplicating.
        var visualCandidates: [MediaManifestEntry] = []
        var seenMediaRefs = Set<String>()
        if let requested = mediaRefs, !requested.isEmpty {
            for ref in requested {
                guard !seenMediaRefs.contains(ref) else { continue }
                if let entry = candidateEntries.first(where: { $0.id == ref }) {
                    visualCandidates.append(entry)
                    seenMediaRefs.insert(ref)
                }
            }
        } else {
            for entry in candidateEntries {
                guard !seenMediaRefs.contains(entry.id) else { continue }
                visualCandidates.append(entry)
                seenMediaRefs.insert(entry.id)
            }
        }

        guard !visualCandidates.isEmpty else {
            throw EditPilotError.noVisualMediaAvailable
        }

        // 2. Identify candidate music/audio asset.
        var musicEntry: MediaManifestEntry?
        if let requestedMusic = musicMediaRef {
            musicEntry = mediaManifest.entries.first { $0.id == requestedMusic }
                ?? mediaAssets.first { $0.id == requestedMusic }.map { asset in
                    MediaManifestEntry(
                        id: asset.id, name: asset.name, type: asset.type,
                        source: .external(absolutePath: asset.url.path), duration: asset.duration
                    )
                }
        } else {
            musicEntry = mediaManifest.entries.first { $0.type == .audio }
                ?? mediaManifest.entries.first {
                    $0.name.localizedCaseInsensitiveContains("music") ||
                    $0.name.localizedCaseInsensitiveContains("beat") ||
                    $0.name.localizedCaseInsensitiveContains("audio")
                }
                ?? mediaAssets.first { $0.type == .audio }.map { asset in
                    MediaManifestEntry(
                        id: asset.id, name: asset.name, type: asset.type,
                        source: .external(absolutePath: asset.url.path), duration: asset.duration
                    )
                }
        }

        // 3. Inspect or estimate music beats.
        var detectedBeats: [Double] = []
        var detectedDownbeats: [Double] = []
        var bpm: Double = 120.0
        if let music = musicEntry {
            if let cached = mediaVisualCache.beats.analysis(for: music.id) {
                detectedBeats = cached.beats
                detectedDownbeats = cached.downbeats
                if cached.bpm > 0 { bpm = cached.bpm }
            } else if let asset = mediaAssetsById[music.id] {
                if let analysis = try? await mediaVisualCache.beats.detect(for: asset).value {
                    detectedBeats = analysis.beats
                    detectedDownbeats = analysis.downbeats
                    if analysis.bpm > 0 { bpm = analysis.bpm }
                }
            }
            if detectedBeats.isEmpty {
                // Fall back to synthetic rhythm grid at detected or standard BPM (e.g. 120 BPM = 0.5s per beat).
                let beatInterval = max(0.2, 60.0 / bpm)
                let totalSec = max(music.duration, 30.0)
                var t = 0.0
                var beatIdx = 0
                while t < totalSec {
                    detectedBeats.append(t)
                    if beatIdx % 4 == 0 { detectedDownbeats.append(t) }
                    t += beatInterval
                    beatIdx += 1
                }
            }
        }

        // 4. Calculate desired duration & block count.
        let defaultDuration = direction.localizedCaseInsensitiveContains("summary") ? 20.0 : 30.0
        let targetDuration = targetDurationSeconds ?? defaultDuration
        let defaultCutSec = resolvedPacing.defaultCutDurationSeconds
        let estimatedBlocks = max(1, Int((targetDuration / defaultCutSec).rounded()))
        let blockCount = min(visualCandidates.count, estimatedBlocks)

        // 5. Construct proposed blocks with beat sync points and contextual captions.
        var blocks: [EditPilotBlock] = []
        var currentFrame = 0
        var currentSourceTime = 0.0

        for i in 0..<blockCount {
            let candidate = visualCandidates[i]
            var cutSeconds = defaultCutSec

            var syncBeatIndex: Int? = nil
            if !detectedBeats.isEmpty {
                let targetSec = currentSourceTime + defaultCutSec
                // Find nearest beat in target range
                if let nearest = detectedBeats.enumerated().min(by: { abs($0.element - targetSec) < abs($1.element - targetSec) }) {
                    let beatDuration = max(resolvedPacing.targetDurationRange.lowerBound, min(resolvedPacing.targetDurationRange.upperBound, nearest.element - currentSourceTime))
                    if beatDuration >= resolvedPacing.targetDurationRange.lowerBound {
                        cutSeconds = beatDuration
                        syncBeatIndex = nearest.offset
                    }
                }
            }

            let durFrames = max(1, Int((cutSeconds * fps).rounded()))
            let startFrame = currentFrame
            let endFrame = startFrame + durFrames
            currentFrame = endFrame
            currentSourceTime += cutSeconds

            let availableDuration = candidate.duration > 0 ? candidate.duration : cutSeconds
            let sourceStart: Double
            let sourceEnd: Double
            if candidate.type == .image {
                sourceStart = 0.0
                sourceEnd = cutSeconds
            } else {
                if availableDuration > cutSeconds + 1.0 {
                    sourceStart = 1.0
                    sourceEnd = sourceStart + cutSeconds
                } else {
                    sourceStart = 0.0
                    sourceEnd = min(availableDuration, cutSeconds)
                }
            }

            let role: String
            let captionText: String
            if i == 0 {
                role = "hook"
                captionText = direction.localizedCaseInsensitiveContains("summary") ? "Quick Social Summary" : "Must-Watch Edit"
            } else if i == blockCount - 1 && blockCount > 2 {
                role = "cta"
                captionText = "Follow & Save For More"
            } else {
                role = "highlight"
                let baseName = candidate.name.components(separatedBy: ".").first ?? "Clip"
                captionText = baseName.replacingOccurrences(of: "_", with: " ").capitalized
            }

            let block = EditPilotBlock(
                id: UUID().uuidString,
                index: i,
                mediaRef: candidate.id,
                mediaName: candidate.name,
                mediaType: candidate.type,
                sourceStartSeconds: sourceStart,
                sourceEndSeconds: sourceEnd,
                durationSeconds: cutSeconds,
                timelineStartFrame: startFrame,
                timelineEndFrame: endFrame,
                durationFrames: durFrames,
                pacing: resolvedPacing,
                musicSyncBeatIndex: syncBeatIndex,
                caption: captionText,
                captionRole: role,
                isApproved: false,
                notes: syncBeatIndex != nil ? "Beat-synced to beat #\(syncBeatIndex!)" : "Paced cut"
            )
            blocks.append(block)
        }

        let musicTrack: EditPilotMusicTrack? = musicEntry.map { entry in
            EditPilotMusicTrack(
                mediaRef: entry.id,
                mediaName: entry.name,
                bpm: bpm,
                startFrame: 0,
                durationFrames: currentFrame,
                volumeDb: -2.0,
                beatCount: detectedBeats.count
            )
        }

        let summary = "Proposed \(blocks.count) blocks (\(String(format: "%.1f", Double(currentFrame) / fps))s) with \(resolvedPacing.rawValue) pacing" + (musicTrack != nil ? " and beat sync." : ".")

        let arrangement = EditPilotArrangement(
            id: UUID().uuidString,
            direction: direction,
            timelineId: activeTimelineId,
            fps: timeline.fps,
            pacing: resolvedPacing,
            targetDurationSeconds: targetDuration,
            totalDurationFrames: currentFrame,
            status: .proposed,
            blocks: blocks,
            musicTrack: musicTrack,
            summary: summary,
            appliedClipIds: nil
        )

        editPilotArrangements[arrangement.id] = arrangement
        return arrangement
    }

    /// Reviews and modifies an individual block in a proposed arrangement.
    func reviewEditPilotBlock(
        arrangementId: String,
        blockId: String,
        isApproved: Bool? = nil,
        sourceStartSeconds: Double? = nil,
        sourceEndSeconds: Double? = nil,
        caption: String? = nil
    ) throws -> EditPilotArrangement {
        guard var arrangement = editPilotArrangements[arrangementId] else {
            throw EditPilotError.arrangementNotFound(arrangementId)
        }
        guard let index = arrangement.blocks.firstIndex(where: { $0.id == blockId }) else {
            throw EditPilotError.blockNotFound(blockId, arrangementId: arrangementId)
        }

        if let approved = isApproved {
            arrangement.blocks[index].isApproved = approved
        }
        if let captionText = caption {
            arrangement.blocks[index].caption = captionText.isEmpty ? nil : captionText
        }
        if let start = sourceStartSeconds, let end = sourceEndSeconds {
            guard start < end else {
                throw EditPilotError.invalidTrim(start: start, end: end)
            }
            arrangement.blocks[index].sourceStartSeconds = start
            arrangement.blocks[index].sourceEndSeconds = end
            let newDuration = end - start
            arrangement.blocks[index].durationSeconds = newDuration
            arrangement.blocks[index].durationFrames = max(1, Int((newDuration * Double(arrangement.fps)).rounded()))

            // Reflow subsequent blocks' start and end frames
            var frame = arrangement.blocks[0].timelineStartFrame
            for i in arrangement.blocks.indices {
                arrangement.blocks[i].timelineStartFrame = frame
                arrangement.blocks[i].timelineEndFrame = frame + arrangement.blocks[i].durationFrames
                frame = arrangement.blocks[i].timelineEndFrame
            }
            arrangement.totalDurationFrames = frame
            if arrangement.musicTrack != nil {
                arrangement.musicTrack?.durationFrames = frame
            }
        }

        // Update arrangement status
        let approvedCount = arrangement.blocks.filter(\.isApproved).count
        if approvedCount == arrangement.blocks.count {
            arrangement.status = .approved
        } else if approvedCount > 0 {
            arrangement.status = .partiallyApproved
        } else {
            arrangement.status = .proposed
        }

        editPilotArrangements[arrangementId] = arrangement
        return arrangement
    }

    /// Approves all blocks in an arrangement.
    func approveAllEditPilotBlocks(arrangementId: String) throws -> EditPilotArrangement {
        guard var arrangement = editPilotArrangements[arrangementId] else {
            throw EditPilotError.arrangementNotFound(arrangementId)
        }
        for i in arrangement.blocks.indices {
            arrangement.blocks[i].isApproved = true
        }
        arrangement.status = .approved
        editPilotArrangements[arrangementId] = arrangement
        return arrangement
    }

    /// Applies approved blocks of an arrangement to the timeline in one atomic undoable action.
    @discardableResult
    func applyEditPilotArrangement(arrangementId: String) throws -> EditPilotReceipt {
        guard var arrangement = editPilotArrangements[arrangementId] else {
            throw EditPilotError.arrangementNotFound(arrangementId)
        }
        guard arrangement.status != .applied else {
            throw EditPilotError.alreadyApplied(arrangementId)
        }

        let approvedBlocks = arrangement.blocks.filter(\.isApproved)
        guard !approvedBlocks.isEmpty else {
            throw EditPilotError.noApprovedBlocks(arrangementId)
        }

        // Enforce visual uniqueness: ensure no visual asset is duplicated in the approved blocks.
        var seenVisuals = Set<String>()
        for block in approvedBlocks {
            guard seenVisuals.insert(block.mediaRef).inserted else {
                throw EditPilotError.duplicateVisualMedia(block.mediaRef)
            }
        }

        var createdVideoClipIds: [String] = []
        var createdAudioClipIds: [String] = []
        var createdTextClipIds: [String] = []
        var trackIds: [String] = []
        let fps = Double(timeline.fps)

        withTimelineSwap(actionName: "EditPilot Arrangement") {
            // 1. Insert video track for visual clips.
            let videoTrackIndex = insertTrack(at: 0, type: .video)
            let videoTrackId = timeline.tracks[videoTrackIndex].id
            trackIds.append(videoTrackId)

            var currentFrame = 0
            for block in approvedBlocks {
                let trimStart = max(0, Int((block.sourceStartSeconds * fps).rounded()))
                let clip = Clip(
                    mediaRef: block.mediaRef,
                    mediaType: block.mediaType,
                    sourceClipType: block.mediaType,
                    startFrame: currentFrame,
                    durationFrames: block.durationFrames,
                    trimStartFrame: trimStart,
                    trimEndFrame: 0
                )
                timeline.tracks[videoTrackIndex].clips.append(clip)
                createdVideoClipIds.append(clip.id)
                currentFrame += block.durationFrames
            }

            // 2. Insert caption text track if any approved block has a caption.
            let blocksWithCaptions = approvedBlocks.filter { $0.caption != nil && !($0.caption!.isEmpty) }
            if !blocksWithCaptions.isEmpty {
                let textTrackIndex = insertTrack(at: 0, type: .video)
                let textTrackId = timeline.tracks[textTrackIndex].id
                trackIds.append(textTrackId)

                var textFrame = 0
                for block in approvedBlocks {
                    if let captionText = block.caption, !captionText.isEmpty {
                        var textClip = Clip(
                            mediaRef: "",
                            mediaType: .text,
                            sourceClipType: .text,
                            startFrame: textFrame,
                            durationFrames: block.durationFrames,
                            textContent: captionText
                        )
                        textClip.textStyle = TextStylePresets.all.first(where: { $0.id == "caption" })?.resolved(canvasHeight: timeline.height) ?? TextStyle()
                        textClip.textAnimation = TextAnimation(preset: .popIn)
                        timeline.tracks[textTrackIndex].clips.append(textClip)
                        createdTextClipIds.append(textClip.id)
                    }
                    textFrame += block.durationFrames
                }
            }

            // 3. Insert audio track for music bed if present.
            if let music = arrangement.musicTrack {
                let audioTrackIndex = insertTrack(at: timeline.tracks.count, type: .audio)
                let audioTrackId = timeline.tracks[audioTrackIndex].id
                trackIds.append(audioTrackId)

                let musicClip = Clip(
                    mediaRef: music.mediaRef,
                    mediaType: .audio,
                    sourceClipType: .audio,
                    startFrame: 0,
                    durationFrames: currentFrame,
                    trimStartFrame: 0,
                    trimEndFrame: 0,
                    volume: 0.8
                )
                timeline.tracks[audioTrackIndex].clips.append(musicClip)
                createdAudioClipIds.append(musicClip.id)
            }
        }

        arrangement.status = .applied
        arrangement.appliedClipIds = createdVideoClipIds + createdAudioClipIds + createdTextClipIds
        editPilotArrangements[arrangementId] = arrangement

        return EditPilotReceipt(
            arrangementId: arrangementId,
            status: arrangement.status.rawValue,
            action: "apply",
            blockCount: approvedBlocks.count,
            approvedBlockCount: approvedBlocks.count,
            totalDurationSeconds: Double(arrangement.totalDurationFrames) / fps,
            totalDurationFrames: arrangement.totalDurationFrames,
            createdVideoClipIds: createdVideoClipIds,
            createdAudioClipIds: createdAudioClipIds,
            createdTextClipIds: createdTextClipIds,
            trackIds: trackIds,
            undoable: true
        )
    }
}
