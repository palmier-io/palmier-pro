import SwiftUI

/// Persisted per-project speaker identity.
struct SpeakerRegistryEntry: Codable, Sendable, Identifiable {
    var id: Int
    var name: String
    var color: [Double]
    var centroid: [Float]
}

struct ProjectSpeaker: Identifiable {
    let id: Int
    var name: String
    var color: Color
}

extension EditorViewModel {

    static let speakerPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .indigo]

    var projectSpeakers: [ProjectSpeaker] {
        speakerRegistry.map { ProjectSpeaker(id: $0.id, name: $0.name, color: Self.color(from: $0.color)) }
    }

    static func color(from rgba: [Double]) -> Color {
        guard rgba.count == 4 else { return .blue }
        return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
    }

    static func rgba(from color: Color) -> [Double] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent]
    }

    func renameSpeaker(id: Int, name: String) {
        guard let i = speakerRegistry.firstIndex(where: { $0.id == id }) else { return }
        speakerRegistry[i].name = name
        onProjectCheckpointRequired?()
    }

    func setSpeakerColor(id: Int, color: Color) {
        guard let i = speakerRegistry.firstIndex(where: { $0.id == id }) else { return }
        speakerRegistry[i].color = Self.rgba(from: color)
        onProjectCheckpointRequired?()
        syncSpeakerColors()
    }

    /// Pushes the current tint palette to the renderer; call after any speaker/toggle change.
    func syncSpeakerColors() {
        ClipRenderer.speakerColors = markSpeakers
            ? Dictionary(uniqueKeysWithValues: projectSpeakers.map {
                ($0.id, NSColor($0.color).withAlphaComponent(AppTheme.Opacity.prominent).cgColor)
            })
            : [:]
        mediaVisualCache.timelineView?.needsDisplay = true
    }

    /// Deletes the label; Identify/Refresh recreates it if the voice is still present.
    func removeSpeaker(id: Int) {
        speakerRegistry.removeAll { $0.id == id }
        for ref in speakerAssignments.keys {
            speakerAssignments[ref] = speakerAssignments[ref]?.filter { $0.value != id }
        }
        onProjectCheckpointRequired?()
        for (ref, mask) in mediaVisualCache.speakerMasks {
            mediaVisualCache.speakerMasks[ref] = mask.map { $0 == id ? -1 : $0 }
        }
        syncSpeakerColors()
    }

    /// `transcribeMissing` is the explicit button only — it costs credits; the auto-run stays cached-only.
    func identifySpeakers(transcribeMissing: Bool = false) {
        guard !speakerIdentifyInFlight else { return }
        if transcribeMissing, !AccountService.shared.isSignedIn {
            speakerIdentifyError = "Sign in to use Cloud transcription."
            return
        }
        speakerIdentifyPhase = transcribeMissing ? "Transcribing…" : "Identifying…"
        speakerIdentifyError = nil
        let projectId = self.projectId
        let assets = mediaAssets.filter { $0.type == .audio || ($0.type == .video && $0.hasAudio) }
        // Cloud transcripts cache under the transcribed source range; mirror the transcript tool's math.
        let rate = Double(max(1, timeline.fps))
        var rangesByRef: [String: ClosedRange<Double>] = [:]
        for clip in captionTargets(ids: []) {
            let span = CaptionTranscriptMapper.sourceSpan(for: clip)
            guard span.end > span.start else { continue }
            let range = max(Double(span.start) / rate - 1.0, 0)...(Double(span.end) / rate + 1.0)
            if let existing = rangesByRef[clip.mediaRef] {
                rangesByRef[clip.mediaRef] = min(existing.lowerBound, range.lowerBound)...max(existing.upperBound, range.upperBound)
            } else {
                rangesByRef[clip.mediaRef] = range
            }
        }
        Task { [weak self] in
            var files: [(mediaRef: String, url: URL, turns: [SpeakerIdentity.Turn])] = []
            for asset in assets {
                var found = await TranscriptCache.shared.cachedCloudTranscript(for: asset.url, range: rangesByRef[asset.id], language: nil)
                if found == nil {
                    found = await TranscriptCache.shared.cachedCloudTranscript(for: asset.url, range: nil, language: nil)
                }
                if found == nil, transcribeMissing, rangesByRef[asset.id] != nil {
                    do {
                        found = try await CloudTranscription.transcribe(
                            fileURL: asset.url, range: rangesByRef[asset.id],
                            preferredLocale: nil, projectId: projectId
                        )
                    } catch {
                        Log.preview.error("identify speakers: transcription failed for \(asset.id): \(Log.detail(error))")
                        if self?.speakerIdentifyError == nil {
                            self?.speakerIdentifyError = Log.detail(error)
                        }
                    }
                }
                guard let transcript = found else {
                    Log.preview.notice("identify speakers: no cached cloud transcript for \(asset.id)")
                    continue
                }
                let turns = await SpeakerIdentity.speechConfirmed(
                    SpeakerIdentity.turns(from: transcript), url: asset.url, mediaRef: asset.id
                )
                if !turns.isEmpty { files.append((asset.id, asset.url, turns)) }
            }
            Log.preview.notice("identify speakers: \(files.count) files with speaker turns")
            self?.speakerIdentifyPhase = "Identifying…"
            let registry = await MainActor.run { self?.speakerRegistry ?? [] }
            let result = await SpeakerIdentity.assignments(
                files: files, registry: registry.map { ($0.id, $0.centroid) }
            )
            guard let self else { return }
            await MainActor.run { [self] in
                self.applySpeakerIdentity(files: files, result: result)
                self.speakerIdentifyPhase = nil
            }
        }
    }

    private func applySpeakerIdentity(files: [(mediaRef: String, url: URL, turns: [SpeakerIdentity.Turn])], result: SpeakerIdentity.Assignments) {
        for entry in result.newEntries {
            speakerRegistry.append(SpeakerRegistryEntry(
                id: entry.id, name: "Speaker \(entry.id)",
                color: Self.rgba(from: Self.speakerPalette[(entry.id - 1) % Self.speakerPalette.count]),
                centroid: entry.centroid
            ))
        }
        var masks: [String: [Int]] = [:]
        for file in files {
            // Prefer the VAD analysis cell count so speaker tints and silence washes share a scale.
            let cellCount: Int
            if let chunks = VoiceActivity.cachedAnalysis(for: file.url, mediaRef: file.mediaRef)?.chunkCount, chunks > 0 {
                cellCount = chunks
            } else if let duration = mediaAssets.first(where: { $0.id == file.mediaRef })?.duration, duration > 0 {
                cellCount = Int(duration / VoiceActivity.chunkDuration) + 1
            } else {
                continue
            }
            var mask = [Int](repeating: -1, count: cellCount)
            for turn in file.turns {
                guard let gid = result.byFileLocal[file.mediaRef]?[turn.speaker] else { continue }
                let lo = max(0, Int(turn.start / VoiceActivity.chunkDuration))
                let hi = min(cellCount, Int((turn.end / VoiceActivity.chunkDuration).rounded(.up)))
                if lo < hi { for c in lo..<hi { mask[c] = gid } }
            }
            masks[file.mediaRef] = mask
        }
        for (ref, mask) in masks { mediaVisualCache.speakerMasks[ref] = mask }
        for (ref, locals) in result.byFileLocal { speakerAssignments[ref] = locals }
        if !result.newEntries.isEmpty { onProjectCheckpointRequired?() }
        syncSpeakerColors()
    }

}
