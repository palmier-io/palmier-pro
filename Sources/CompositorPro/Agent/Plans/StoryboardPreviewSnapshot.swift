import CryptoKit
import Foundation

enum StoryboardPreviewError: String, Error, LocalizedError, Sendable {
    case emptyStoryboard
    case unsupportedLayout
    case unresolvedTiming
    case unavailableSource
    case unsupportedSource
    case sourceMismatch
    case renderIncomplete
    case tooLong
    case stale
    case canceled

    var errorDescription: String? { rawValue }
}

struct StoryboardPreviewSnapshot: Sendable {
    let plan: EditPlan
    let report: StoryboardReport
    let timeline: Timeline
    let sources: [Source]
    let key: String
    let measured: Bool

    var frameCount: Int { timeline.totalFrames }

    struct Source: Codable, Equatable, Sendable {
        let mediaRef: String
        let url: URL
        let type: ClipType
        let expectedInputId: String?
        let duration: Double
    }

    private struct KeyPayload: Encodable {
        let plan: EditPlan
        let storyboardRevision: String
        let timeline: Timeline
        let sources: [Source]
        let identities: [MediaInputIdentity?]
        let measured: Bool
    }

    private struct VerifiedKeyPayload: Encodable {
        struct Source: Encodable {
            let mediaRef: String
            let identity: MediaInputIdentity
        }

        let requestKey: String
        let sources: [Source]
    }

    func verifiedKey(identities: [String: MediaInputIdentity]) throws -> String {
        guard Set(identities.keys) == Set(sources.map(\.mediaRef)),
              identities.values.allSatisfy(\.isValid) else { throw StoryboardPreviewError.sourceMismatch }
        for source in sources {
            if let expected = source.expectedInputId, identities[source.mediaRef]?.inputId != expected {
                throw StoryboardPreviewError.sourceMismatch
            }
        }
        guard sources.contains(where: { $0.expectedInputId == nil }) else { return key }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let verified = try sources.sorted { $0.mediaRef < $1.mediaRef }.map { source in
            guard let identity = identities[source.mediaRef] else { throw StoryboardPreviewError.sourceMismatch }
            return VerifiedKeyPayload.Source(mediaRef: source.mediaRef, identity: identity)
        }
        let data = try encoder.encode(VerifiedKeyPayload(requestKey: key, sources: verified))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @concurrent
    static func make(
        plan: EditPlan,
        manifest: MediaManifest,
        projectURL: URL?,
        transforms: [String: Transform] = [:],
        unavailable: Set<String> = []
    ) async throws -> Self {
        do {
            try Task.checkCancellation()
            try EditPlan.validatedGeometry(fps: plan.fps, width: plan.width, height: plan.height)
            guard !plan.shots.isEmpty else { throw StoryboardPreviewError.emptyStoryboard }
            guard plan.shots.count <= EditPlanLimits.maximumShots,
                  try EditPlan.validatedID(plan.id, field: "planId") == plan.id else {
                throw StoryboardPreviewError.unsupportedLayout
            }
            let limit = plan.fps.multipliedReportingOverflow(by: 1_800)
            guard !limit.overflow else { throw StoryboardPreviewError.tooLong }
            var shotIds: Set<String> = []
            var authoredEnd = 0
            for shot in plan.shots {
                try Task.checkCancellation()
                guard try EditPlan.validatedID(shot.id, field: "shotId") == shot.id,
                      shotIds.insert(shot.id).inserted else { throw StoryboardPreviewError.unsupportedLayout }
                try EditPlan.validatedFrames(start: shot.startFrame, end: shot.endFrame)
                guard shot.startFrame == authoredEnd else { throw StoryboardPreviewError.unsupportedLayout }
                authoredEnd = shot.endFrame
            }
            var entries: [String: MediaManifestEntry] = [:]
            for entry in manifest.entries {
                try Task.checkCancellation()
                guard try EditPlan.validatedID(entry.id, field: "mediaRef") == entry.id,
                      entries.updateValue(entry, forKey: entry.id) == nil else {
                    throw StoryboardPreviewError.unsupportedLayout
                }
            }
            let urls = MediaResolver.expectedURLMap(entries: manifest.entries, projectURL: projectURL)
            let measured = plan.narrationTiming != nil
            var selectedRefs = Set(plan.shots.compactMap(\.mediaRef))
            if measured, let narration = plan.narration { selectedRefs.insert(narration.mediaRef) }
            for ref in selectedRefs {
                guard let entry = entries[ref], !unavailable.contains(ref), entry.generationStatus == nil else {
                    throw StoryboardPreviewError.unavailableSource
                }
                guard entry.duration.isFinite, entry.duration >= 0 else { throw StoryboardPreviewError.unresolvedTiming }
            }
            let report = try await StoryboardResolver.resolve(plan: plan, manifest: manifest, unavailable: unavailable)
            var clips: [Clip] = []
            var visualEnd = 0
            for card in report.cards {
                try Task.checkCancellation()
                guard let ref = card.shot.mediaRef, let entry = entries[ref] else {
                    throw StoryboardPreviewError.unavailableSource
                }
                guard entry.type == .image || entry.type == .video else { throw StoryboardPreviewError.unsupportedSource }
                if measured, card.resolvedRange == nil { throw StoryboardPreviewError.unresolvedTiming }
                let range = card.resolvedRange ?? (card.shot.startFrame..<card.shot.endFrame)
                guard range.lowerBound == visualEnd else { throw StoryboardPreviewError.unsupportedLayout }
                guard range.upperBound <= limit.partialValue else { throw StoryboardPreviewError.tooLong }
                guard let playback = card.playbackRange else {
                    if card.blockers.contains(PlanSourceRangeError.outsideSource.blocker)
                        || card.blockers.contains(PlanSourceRangeError.durationMismatch.blocker) {
                        throw StoryboardPreviewError.sourceMismatch
                    }
                    throw StoryboardPreviewError.unresolvedTiming
                }
                let transform = transforms[ref] ?? Transform()
                guard [transform.centerX, transform.centerY, transform.width, transform.height,
                       transform.rotation, transform.rotationX, transform.rotationY].allSatisfy(\.isFinite),
                      transform.width > 0, transform.height > 0,
                      Transform.tiltRotationRange.contains(transform.rotationX),
                      Transform.tiltRotationRange.contains(transform.rotationY) else {
                    throw StoryboardPreviewError.unsupportedLayout
                }
                clips.append(Clip(id: "preview-scene:\(card.shot.id)", mediaRef: ref, mediaType: entry.type,
                    sourceClipType: entry.type, startFrame: range.lowerBound, durationFrames: range.count,
                    trimStartFrame: playback.lowerBound, volume: 0, transform: transform))
                visualEnd = range.upperBound
            }
            var tracks = [Track(id: "storyboard-preview-video:\(plan.id)", type: .video, clips: clips)]
            if let timing = plan.narrationTiming {
                guard let narration = plan.narration, let entry = entries[narration.mediaRef] else {
                    throw StoryboardPreviewError.unresolvedTiming
                }
                guard entry.type == .audio else { throw StoryboardPreviewError.unsupportedSource }
                if let identity = entry.inputIdentity {
                    guard identity.isValid, identity.contentSHA256 == timing.sourceFingerprint else {
                        throw StoryboardPreviewError.sourceMismatch
                    }
                }
                let duration = try timing.duration.frame(fps: plan.fps, rounding: .roundTowardZero)
                guard narration.startFrame == 0, duration == visualEnd else { throw StoryboardPreviewError.renderIncomplete }
                let audioShot = EditPlanShot(id: "preview-narration", title: "Narration", startFrame: narration.startFrame,
                    endFrame: visualEnd, mediaRef: narration.mediaRef)
                _ = try PlanSourceRange.playback(shot: audioShot, fps: plan.fps, type: entry.type, duration: entry.duration)
                let audio = Clip(id: "preview-narration:\(plan.id)", mediaRef: narration.mediaRef, mediaType: .audio,
                    sourceClipType: .audio, startFrame: narration.startFrame, durationFrames: duration)
                tracks.append(Track(id: "storyboard-preview-audio:\(plan.id)", type: .audio, clips: [audio]))
            }
            let sources = try selectedRefs.sorted().map { ref -> Source in
                try Task.checkCancellation()
                guard let entry = entries[ref], let url = urls[ref], url.isFileURL, !url.path.isEmpty else {
                    throw StoryboardPreviewError.unavailableSource
                }
                switch entry.source {
                case .external(let path):
                    guard (path as NSString).isAbsolutePath else { throw StoryboardPreviewError.unavailableSource }
                case .project(let path):
                    guard !path.isEmpty, !(path as NSString).isAbsolutePath,
                          !path.split(separator: "/").contains("..") else { throw StoryboardPreviewError.unavailableSource }
                }
                if let identity = entry.inputIdentity, !identity.isValid { throw StoryboardPreviewError.sourceMismatch }
                let expectedInputId = measured && ref == plan.narration?.mediaRef
                    ? plan.narrationTiming.map { "sha256:\($0.sourceFingerprint)" }
                    : entry.inputIdentity?.inputId
                return Source(mediaRef: ref, url: url, type: entry.type, expectedInputId: expectedInputId, duration: entry.duration)
            }
            let timeline = Timeline(id: "storyboard-preview:\(plan.id)", name: plan.name, fps: plan.fps,
                width: plan.width, height: plan.height, settingsConfigured: true, tracks: tracks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = KeyPayload(plan: plan, storyboardRevision: report.revision, timeline: timeline,
                sources: sources, identities: sources.map { entries[$0.mediaRef]?.inputIdentity }, measured: measured)
            let key = SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            return Self(plan: plan, report: report, timeline: timeline, sources: sources, key: key, measured: measured)
        } catch is CancellationError {
            throw StoryboardPreviewError.canceled
        } catch let error as StoryboardPreviewError {
            throw error
        } catch let error as PlanSourceRangeError {
            switch error {
            case .outsideSource, .durationMismatch: throw StoryboardPreviewError.sourceMismatch
            case .invalidTime, .unknownDuration: throw StoryboardPreviewError.unresolvedTiming
            }
        } catch let error as EditPlanValidationError {
            if error == .invalidRange { throw StoryboardPreviewError.unresolvedTiming }
            throw StoryboardPreviewError.unsupportedLayout
        } catch {
            throw StoryboardPreviewError.unsupportedLayout
        }
    }
}
