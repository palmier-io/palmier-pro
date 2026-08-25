import Foundation

enum TemplateMode: String, Codable, Sendable {
    /// Fillable placeholder slots the user drops their own media onto.
    case placeholders
    /// The reel split into its detected shots, still referencing the original media.
    case originalCuts
}

enum TemplateWarning: String, Sendable {
    case noCutsDetected
    case noMusicDetected
    case noAudioTrack

    @MainActor
    var message: String {
        switch self {
        case .noCutsDetected:
            L10n.string("No cuts were detected; the template has a single slot covering the whole reel.")
        case .noMusicDetected:
            L10n.string("No music was detected in the reel's audio.")
        case .noAudioTrack:
            L10n.string("The reel has no audio track; no audio lanes were generated.")
        }
    }
}

struct TemplateOptions: Sendable {
    var name: String
    var mode: TemplateMode = .placeholders
    var includeAudioLanes = true
}

struct TemplateGenerationResult: Sendable {
    var timeline: Timeline
    /// Clip IDs of the generated slots, in shot order.
    var slotClipIds: [String]
    var warnings: [TemplateWarning]
}

/// Turns a `ReelAnalysis` into an ordinary `Timeline`. All frame math happens
/// here once, in the generated timeline's fps domain.
enum TemplateGenerator {
    static func makeTimeline(
        from analysis: ReelAnalysis,
        sourceMediaRef: String,
        options: TemplateOptions
    ) -> TemplateGenerationResult {
        let fps = max(1, min(240, Int(analysis.sourceFPS.rounded())))
        let sourceFrames = frame(forSeconds: analysis.durationSeconds, fps: fps)
        var warnings: [TemplateWarning] = []

        let slots = slotClips(
            shots: analysis.shots,
            sourceMediaRef: sourceMediaRef,
            sourceFrames: sourceFrames,
            fps: fps,
            mode: options.mode
        )
        if slots.count <= 1 { warnings.append(.noCutsDetected) }

        var tracks = [Track(type: .video, clips: slots)]
        if options.includeAudioLanes {
            if analysis.hasAudio {
                tracks.append(contentsOf: audioLanes(
                    analysis: analysis,
                    sourceMediaRef: sourceMediaRef,
                    sourceFrames: sourceFrames,
                    fps: fps
                ))
                if analysis.musicSegments.isEmpty { warnings.append(.noMusicDetected) }
            } else {
                warnings.append(.noAudioTrack)
            }
        }

        let timeline = Timeline(
            name: options.name,
            fps: fps,
            width: analysis.sourceWidth,
            height: analysis.sourceHeight,
            settingsConfigured: true,
            tracks: tracks
        )
        return TemplateGenerationResult(
            timeline: timeline,
            slotClipIds: slots.map(\.id),
            warnings: warnings
        )
    }

    // MARK: - Video slots

    private static func slotClips(
        shots: [DetectedShot],
        sourceMediaRef: String,
        sourceFrames: Int,
        fps: Int,
        mode: TemplateMode
    ) -> [Clip] {
        // Boundaries come from absolute shot times so rounding never accumulates drift.
        let boundaries = shots.map { frame(forSeconds: $0.startSeconds, fps: fps) } + [sourceFrames]

        var clips: [Clip] = []
        for (index, shot) in shots.enumerated() {
            let startFrame = boundaries[index]
            let durationFrames = boundaries[index + 1] - startFrame
            guard durationFrames > 0 else { continue }

            var clip: Clip
            switch mode {
            case .placeholders:
                clip = Clip(
                    mediaRef: Clip.templateSlotMediaRef,
                    startFrame: startFrame,
                    durationFrames: durationFrames
                )
            case .originalCuts:
                clip = Clip(
                    mediaRef: sourceMediaRef,
                    startFrame: startFrame,
                    durationFrames: durationFrames,
                    trimStartFrame: startFrame,
                    trimEndFrame: max(0, sourceFrames - startFrame - durationFrames)
                )
            }
            clip.templateSlot = TemplateSlot(
                index: clips.count + 1,
                motionEnergy: shot.motionEnergy,
                suggestedSpeed: MotionEnergyEstimator.suggestedSpeed(for: shot)
            )
            clips.append(clip)
        }
        return clips
    }

    // MARK: - Audio lanes

    private static func audioLanes(
        analysis: ReelAnalysis,
        sourceMediaRef: String,
        sourceFrames: Int,
        fps: Int
    ) -> [Track] {
        let lanes: [(kind: AudioSegmentKind, segments: [AudioSegment])] = [
            (.music, analysis.musicSegments),
            (.speech, analysis.speechSegments),
        ]
        return lanes.compactMap { lane in
            let clips = audioClips(
                for: lane.segments,
                sourceMediaRef: sourceMediaRef,
                sourceFrames: sourceFrames,
                fps: fps
            )
            guard !clips.isEmpty else { return nil }
            return Track(type: .audio, name: lane.kind.trackName, clips: clips)
        }
    }

    private static func audioClips(
        for segments: [AudioSegment],
        sourceMediaRef: String,
        sourceFrames: Int,
        fps: Int
    ) -> [Clip] {
        segments.compactMap { segment in
            let startFrame = frame(forSeconds: segment.startSeconds, fps: fps)
            let durationFrames = min(frame(forSeconds: segment.endSeconds, fps: fps), sourceFrames) - startFrame
            guard durationFrames > 0 else { return nil }
            return Clip(
                mediaRef: sourceMediaRef,
                mediaType: .audio,
                startFrame: startFrame,
                durationFrames: durationFrames,
                trimStartFrame: startFrame,
                trimEndFrame: max(0, sourceFrames - startFrame - durationFrames)
            )
        }
    }

    private static func frame(forSeconds seconds: Double, fps: Int) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((seconds * Double(fps)).rounded()))
    }
}
