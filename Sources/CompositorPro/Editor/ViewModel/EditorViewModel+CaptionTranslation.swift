import CoreMedia
import Foundation

extension EditorViewModel {

    /// Translates script beats or existing captions into a target language, synced to narration timing.
    func translateCaptions(
        targetLanguage: String,
        planId: String? = nil,
        beats: [CaptionTranslationInputBeat]? = nil,
        captionStyle: String? = nil,
        customTranslations: [String: String]? = nil
    ) async throws -> CaptionTranslationJob {
        let language = CaptionLanguage.resolve(targetLanguage)
        let resolvedStyleId: String
        if let requestedStyle = captionStyle {
            guard let preset = CaptionStyles.preset(id: requestedStyle) else {
                throw CaptionTranslationError.unknownCaptionStyle(requestedStyle)
            }
            resolvedStyleId = preset.id
        } else {
            resolvedStyleId = CaptionStyles.defaultStyle.id
        }

        let fps = max(1, timeline.fps)
        struct RawBeat {
            let beatId: String
            let text: String
            let startFrame: Int?
            let endFrame: Int?
            let startSeconds: Double?
            let endSeconds: Double?
        }

        var sourceBeats: [RawBeat] = []

        // Case A: Explicit beats supplied in arguments
        if let rawBeats = beats, !rawBeats.isEmpty {
            for (idx, b) in rawBeats.enumerated() {
                guard !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let beatId = b.beatId ?? "beat_\(idx + 1)"
                sourceBeats.append(RawBeat(
                    beatId: beatId,
                    text: b.text,
                    startFrame: b.startFrame,
                    endFrame: b.endFrame,
                    startSeconds: b.startSeconds,
                    endSeconds: b.endSeconds
                ))
            }
        }
        // Case B: Read from an EditPlan
        else if let requestedPlanId = planId ?? editPlans.first(where: { $0.timelineId == activeTimelineId })?.id {
            guard let plan = editPlans.first(where: { $0.id == requestedPlanId }),
                  let scriptBeats = plan.scriptBeats, !scriptBeats.isEmpty else {
                throw CaptionTranslationError.noScriptBeatsFound
            }
            for beat in scriptBeats {
                var startF: Int? = nil
                var endF: Int? = nil
                var startS: Double? = nil
                var endS: Double? = nil
                if let anchor = plan.narrationTiming?.anchors.first(where: { $0.beatId == beat.beatId }) {
                    startF = try? anchor.speechStart.frame(fps: fps)
                    endF = try? anchor.speechEnd.frame(fps: fps)
                    startS = anchor.speechStart.cmTime.seconds
                    endS = anchor.speechEnd.cmTime.seconds
                }
                sourceBeats.append(RawBeat(
                    beatId: beat.beatId, text: beat.narrationText,
                    startFrame: startF, endFrame: endF,
                    startSeconds: startS, endSeconds: endS
                ))
            }
        }
        // Case C: Read from existing timeline text / caption clips
        else {
            let textClips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text && !($0.textContent ?? "").isEmpty }
                .sorted { $0.startFrame < $1.startFrame }
            for (idx, clip) in textClips.enumerated() {
                let content = clip.textContent ?? ""
                let sFrame = clip.startFrame
                let eFrame = clip.endFrame
                sourceBeats.append(RawBeat(
                    beatId: clip.id.isEmpty ? "clip_\(idx + 1)" : clip.id,
                    text: content,
                    startFrame: sFrame,
                    endFrame: eFrame,
                    startSeconds: Double(sFrame) / Double(fps),
                    endSeconds: Double(eFrame) / Double(fps)
                ))
            }
        }

        guard !sourceBeats.isEmpty else {
            throw CaptionTranslationError.noScriptBeatsFound
        }

        // Construct translated caption segments with exact or estimated narration timing
        var segments: [TranslatedCaptionSegment] = []
        var accumulatedFrame = 0

        for beat in sourceBeats {
            let translated: String
            if let custom = customTranslations?[beat.beatId] ?? customTranslations?[beat.text] {
                translated = custom
            } else {
                translated = CaptionTranslator.translate(text: beat.text, targetLanguage: language)
            }

            let startF: Int
            let endF: Int
            let startS: Double
            let endS: Double

            if let sf = beat.startFrame, let ef = beat.endFrame, ef > sf {
                startF = sf
                endF = ef
                startS = beat.startSeconds ?? (Double(sf) / Double(fps))
                endS = beat.endSeconds ?? (Double(ef) / Double(fps))
                accumulatedFrame = ef
            } else if let ss = beat.startSeconds, let es = beat.endSeconds, es > ss {
                startS = ss
                endS = es
                startF = max(0, Int((ss * Double(fps)).rounded()))
                endF = max(startF + 1, Int((es * Double(fps)).rounded()))
                accumulatedFrame = endF
            } else {
                // Estimate timing from speech cadence (~2.5 words per second)
                let words = max(1, beat.text.split(separator: " ").count)
                let durSec = max(1.5, min(8.0, Double(words) / 2.5))
                let durFrames = max(1, Int((durSec * Double(fps)).rounded()))
                startF = accumulatedFrame
                endF = startF + durFrames
                startS = Double(startF) / Double(fps)
                endS = Double(endF) / Double(fps)
                accumulatedFrame = endF
            }

            let segment = TranslatedCaptionSegment(
                id: UUID().uuidString,
                beatId: beat.beatId,
                sourceText: beat.text,
                translatedText: translated,
                targetLanguage: language.code,
                targetLanguageName: language.name,
                startFrame: startF,
                endFrame: endF,
                startSeconds: startS,
                endSeconds: endS,
                captionStyle: resolvedStyleId,
                isApproved: false
            )
            segments.append(segment)
        }

        let totalDuration = segments.map(\.endSeconds).max() ?? 0.0

        let job = CaptionTranslationJob(
            id: UUID().uuidString,
            targetLanguage: language.code,
            targetLanguageName: language.name,
            captionStyle: resolvedStyleId,
            status: .translated,
            segments: segments,
            totalSegments: segments.count,
            totalDurationSeconds: totalDuration,
            timelineId: activeTimelineId,
            appliedClipIds: nil,
            trackId: nil
        )

        captionTranslationJobs[job.id] = job
        return job
    }

    /// Reviews or modifies an individual translated caption segment in a job.
    func reviewTranslatedCaptionSegment(
        jobId: String,
        segmentId: String,
        translatedText: String? = nil,
        startFrame: Int? = nil,
        endFrame: Int? = nil,
        isApproved: Bool? = nil
    ) throws -> CaptionTranslationJob {
        guard var job = captionTranslationJobs[jobId] else {
            throw CaptionTranslationError.jobNotFound(jobId)
        }
        guard let index = job.segments.firstIndex(where: { $0.id == segmentId || $0.beatId == segmentId }) else {
            throw CaptionTranslationError.segmentNotFound(segmentId, jobId: jobId)
        }

        if let text = translatedText {
            job.segments[index].translatedText = text
        }
        if let approved = isApproved {
            job.segments[index].isApproved = approved
        }
        if let sf = startFrame, let ef = endFrame {
            guard sf < ef else {
                throw CaptionTranslationError.invalidTiming(startFrame: sf, endFrame: ef)
            }
            job.segments[index].startFrame = sf
            job.segments[index].endFrame = ef
            job.segments[index].startSeconds = Double(sf) / Double(max(1, timeline.fps))
            job.segments[index].endSeconds = Double(ef) / Double(max(1, timeline.fps))
        }

        let approvedCount = job.segments.filter(\.isApproved).count
        if approvedCount == job.segments.count {
            job.status = .approved
        } else if approvedCount > 0 {
            job.status = .partiallyApproved
        } else {
            job.status = .translated
        }

        captionTranslationJobs[jobId] = job
        return job
    }

    /// Approves all translated caption segments in a job.
    func approveAllTranslatedCaptionSegments(jobId: String) throws -> CaptionTranslationJob {
        guard var job = captionTranslationJobs[jobId] else {
            throw CaptionTranslationError.jobNotFound(jobId)
        }
        for i in job.segments.indices {
            job.segments[i].isApproved = true
        }
        job.status = .approved
        captionTranslationJobs[jobId] = job
        return job
    }

    /// Applies approved translated caption segments to the timeline in one atomic undo action.
    @discardableResult
    func applyTranslatedCaptions(
        jobId: String,
        trackIndex: Int? = nil,
        trackName: String? = nil
    ) throws -> CaptionTranslationReceipt {
        guard var job = captionTranslationJobs[jobId] else {
            throw CaptionTranslationError.jobNotFound(jobId)
        }
        guard job.status != .applied else {
            throw CaptionTranslationError.alreadyApplied(jobId)
        }

        let approvedSegments = job.segments.filter(\.isApproved)
        guard !approvedSegments.isEmpty else {
            throw CaptionTranslationError.noApprovedSegments(jobId)
        }

        var createdClipIds: [String] = []
        var trackId: String = ""
        var placedTrackIndex: Int = 0

        withTimelineSwap(actionName: "Apply Translated Captions (\(job.targetLanguageName))") {
            let insertionIndex = trackIndex ?? 0
            placedTrackIndex = insertTrack(at: insertionIndex, type: .video)
            trackId = timeline.tracks[placedTrackIndex].id

            let resolvedTrackName = trackName ?? "Captions (\(job.targetLanguageName))"
            try? setTrackName(id: trackId, to: resolvedTrackName)

            let preset = CaptionStyles.preset(id: job.captionStyle) ?? CaptionStyles.defaultStyle
            let resolved = preset.resolved(canvasHeight: timeline.height)
            let captionGroupId = UUID().uuidString

            for segment in approvedSegments {
                var clip = Clip(
                    mediaRef: "",
                    mediaType: .text,
                    sourceClipType: .text,
                    startFrame: segment.startFrame,
                    durationFrames: max(1, segment.endFrame - segment.startFrame),
                    textContent: segment.translatedText
                )
                clip.captionGroupId = captionGroupId
                clip.textStyle = resolved.style
                clip.textAnimation = resolved.animation
                clip.transform.centerY = resolved.center.1
                timeline.tracks[placedTrackIndex].clips.append(clip)
                createdClipIds.append(clip.id)
            }
        }

        job.status = .applied
        job.trackId = trackId
        job.appliedClipIds = createdClipIds
        captionTranslationJobs[jobId] = job

        let fps = Double(max(1, timeline.fps))
        let maxFrame = approvedSegments.map(\.endFrame).max() ?? 0

        return CaptionTranslationReceipt(
            jobId: jobId,
            targetLanguage: job.targetLanguage,
            targetLanguageName: job.targetLanguageName,
            trackId: trackId,
            trackIndex: placedTrackIndex,
            captionClipIds: createdClipIds,
            segmentCount: approvedSegments.count,
            totalDurationSeconds: Double(maxFrame) / fps,
            totalDurationFrames: maxFrame,
            undoable: true
        )
    }
}
