import CoreMedia
import Foundation
import Testing
@testable import CompositorPro

private enum StoryboardPreviewFixtures {
    static func inputs(measured: Bool = false) throws -> (plan: EditPlan, manifest: MediaManifest) {
        var plan = EditPlan(id: "preview-plan", name: "Storyboard", timelineId: "editor-timeline",
            fps: 30, width: 1080, height: 1920, shots: [
                .init(id: "first-scene", title: "First", startFrame: 0, endFrame: 60, mediaRef: "video",
                    sourceStartSeconds: 2, sourceEndSeconds: measured ? 3.5 : 4,
                    narrationLink: .init(firstBeatId: "first-beat", lastBeatId: "first-beat")),
                .init(id: "second-scene", title: "Second", startFrame: 60, endFrame: 120, mediaRef: "image",
                    narrationLink: .init(firstBeatId: "second-beat", lastBeatId: "second-beat")),
            ], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            scriptBeats: PlanNarrationFixtures.beats(), narration: .init(mediaRef: "audio", startFrame: 0))
        if measured { plan.narrationTiming = try PlanNarrationFixtures.timing(revision: #require(plan.narrationRevision)) }
        var manifest = MediaManifest()
        manifest.entries = [
            .init(id: "video", name: "Video", type: .video, source: .external(absolutePath: "/preview-fixture/video.mov"),
                duration: 10, inputIdentity: .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 100)),
            .init(id: "image", name: "Image", type: .image, source: .external(absolutePath: "/preview-fixture/image.png"), duration: 0),
            .init(id: "audio", name: "Voice", type: .audio, source: .external(absolutePath: "/preview-fixture/voice.wav"),
                duration: 3, inputIdentity: .init(contentSHA256: PlanNarrationFixtures.fingerprint, byteCount: 200)),
        ]
        return (plan, manifest)
    }
}

struct StoryboardPreviewSnapshotTests {
    @Test func verifiedKeyPinsPreviouslyUnhashedSourceContents() async throws {
        let inputs = try StoryboardPreviewFixtures.inputs()
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: inputs.plan, manifest: inputs.manifest, projectURL: nil)
        let first = MediaInputIdentity(contentSHA256: String(repeating: "a", count: 64), byteCount: 1)
        let second = MediaInputIdentity(contentSHA256: String(repeating: "b", count: 64), byteCount: 1)
        let original = Dictionary(uniqueKeysWithValues: snapshot.sources.map { source in
            (source.mediaRef, inputs.manifest.entries.first { $0.id == source.mediaRef }?.inputIdentity ?? first)
        })
        var replacement = original
        replacement["image"] = second
        #expect(try snapshot.verifiedKey(identities: original) != snapshot.key)
        #expect(try snapshot.verifiedKey(identities: original) != snapshot.verifiedKey(identities: replacement))
        #expect(try snapshot.verifiedKey(identities: original) == snapshot.verifiedKey(identities: original))
    }

    @Test func verifiedKeyRejectsMissingOrInvalidSourceIdentities() async throws {
        let inputs = try StoryboardPreviewFixtures.inputs()
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: inputs.plan, manifest: inputs.manifest, projectURL: nil)
        #expect(throws: StoryboardPreviewError.sourceMismatch) { try snapshot.verifiedKey(identities: [:]) }
        let identities = Dictionary(uniqueKeysWithValues: snapshot.sources.map {
            ($0.mediaRef, MediaInputIdentity(contentSHA256: "invalid", byteCount: 0))
        })
        #expect(throws: StoryboardPreviewError.sourceMismatch) { try snapshot.verifiedKey(identities: identities) }
    }

    @Test func unapprovedStoryboardProducesEstimatedSilentPreviewWithoutChangingInputs() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        var ledger = SourceClaimLedgerFixtures.ledger()
        ledger.claims[0].status = .unresolved
        plan.sourceLedger = ledger
        plan.shots[0].claimIds = [ledger.claims[0].claimId]
        manifest.entries[0].generationInput = .init(prompt: "Visual", model: "model", duration: 10, aspectRatio: "9:16")
        manifest.entries[2].generationStatus = "pending"
        let originalPlan = plan
        let originalManifest = manifest
        let transform = Transform(width: 1, height: 0.5)
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil,
            transforms: ["video": transform], unavailable: ["audio"])

        #expect(!snapshot.measured)
        #expect(!snapshot.report.canProduce)
        #expect(snapshot.report.blockers.contains("unresolved_claim:\(ledger.claims[0].claimId)"))
        #expect(snapshot.timeline.id == "storyboard-preview:\(plan.id)")
        #expect(snapshot.timeline.fps == plan.fps)
        #expect(snapshot.timeline.width == plan.width && snapshot.timeline.height == plan.height)
        #expect(snapshot.frameCount == 120)
        #expect(snapshot.timeline.tracks.count == 1)
        #expect(snapshot.timeline.tracks[0].type == .video)
        #expect(snapshot.timeline.tracks[0].clips.map(\.id) == ["preview-scene:first-scene", "preview-scene:second-scene"])
        #expect(snapshot.timeline.tracks[0].clips.allSatisfy { $0.volume == 0 })
        #expect(snapshot.timeline.tracks[0].clips[0].transform == transform)
        #expect(snapshot.timeline.tracks[0].clips[0].trimStartFrame == 60)
        #expect(snapshot.sources.map(\.mediaRef) == ["image", "video"])
        #expect(snapshot.sources.first { $0.mediaRef == "image" }?.expectedInputId == nil)
        #expect(snapshot.plan == originalPlan && plan == originalPlan)
        #expect(manifest == originalManifest)
    }

    @Test func measuredTimelineUsesExactResolverRangesAndFullNarration() async throws {
        let (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        let report = try await StoryboardResolver.resolve(plan: plan, manifest: manifest)
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        #expect(snapshot.measured)
        #expect(snapshot.report.revision == report.revision)
        let clips = snapshot.timeline.tracks[0].clips
        for (clip, card) in zip(clips, report.cards) {
            let range = try #require(card.resolvedRange)
            #expect(clip.startFrame == range.lowerBound)
            #expect(clip.endFrame == range.upperBound)
            #expect(clip.trimStartFrame == card.playbackRange?.lowerBound)
        }
        #expect(clips.map(\.durationFrames) == [45, 45])
        let audio = try #require(snapshot.timeline.tracks.first { $0.type == .audio }?.clips.first)
        #expect(audio.startFrame == plan.narration?.startFrame)
        #expect(audio.durationFrames == 90 && audio.endFrame == snapshot.frameCount)
        #expect(audio.trimStartFrame == 0 && audio.volume == 1)
        #expect(snapshot.sources.map(\.mediaRef) == ["audio", "image", "video"])
        #expect(snapshot.plan == plan)
    }

    @Test func measuredNarrationWithoutManifestIdentityStillPinsMeasuredFingerprint() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        manifest.entries[2].inputIdentity = nil
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        #expect(snapshot.sources.first { $0.mediaRef == "audio" }?.expectedInputId == "sha256:\(PlanNarrationFixtures.fingerprint)")
        #expect(manifest.entries[2].inputIdentity == nil)
        #expect(snapshot.plan == plan)
    }

    @Test(arguments: ["fingerprint", "invalid identity", "audio too short", "visual span"])
    func mismatchedSourcesAreRefused(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        switch failure {
        case "fingerprint": manifest.entries[2].inputIdentity = .init(contentSHA256: String(repeating: "c", count: 64), byteCount: 200)
        case "invalid identity": manifest.entries[0].inputIdentity = .init(contentSHA256: "bad", byteCount: 100)
        case "audio too short": manifest.entries[2].duration = 2
        default: plan.shots[0].sourceEndSeconds = 4
        }
        await #expect(throws: StoryboardPreviewError.sourceMismatch) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["gap", "overlap", "nonzero start", "reordered", "duplicate scene", "duplicate media"])
    func nonSequentialOrAmbiguousBoardsAreRefused(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        switch failure {
        case "gap": plan.shots[1].startFrame += 1
        case "overlap": plan.shots[1].startFrame -= 1
        case "nonzero start": plan.shots[0].startFrame = 1
        case "reordered": plan.shots.reverse()
        case "duplicate scene": plan.shots[1].id = plan.shots[0].id
        default: manifest.entries.append(manifest.entries[0])
        }
        await #expect(throws: StoryboardPreviewError.unsupportedLayout) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["missing selection", "missing media", "generation", "unavailable", "unresolved project", "relative external"])
    func unavailableVisualsAreRefused(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        var unavailable: Set<String> = []
        switch failure {
        case "missing selection": plan.shots[0].mediaRef = nil
        case "missing media": manifest.entries.removeFirst()
        case "generation": manifest.entries[0].generationStatus = "pending"
        case "unavailable": unavailable.insert("video")
        case "unresolved project": manifest.entries[0].source = .project(relativePath: "media/video.mov")
        default: manifest.entries[0].source = .external(absolutePath: "video.mov")
        }
        await #expect(throws: StoryboardPreviewError.unavailableSource) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil, unavailable: unavailable)
        }
    }

    @Test(arguments: [ClipType.audio, .text, .lottie, .sequence, .subtitle])
    func nonImageVideoVisualsAreRefused(type: ClipType) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        manifest.entries[0].type = type
        await #expect(throws: StoryboardPreviewError.unsupportedSource) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["missing link", "stale revision", "unresolved beat", "short hold", "unknown duration"])
    func unresolvedMeasuredTimingNeverFallsBackToEstimated(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        switch failure {
        case "missing link": plan.shots[1].narrationLink = nil
        case "stale revision": plan.narrationTiming?.revision = UUID().uuidString
        case "unresolved beat": plan.narrationTiming?.unresolvedBeatIds = ["second-beat"]
        case "short hold": plan.shots[1].narrationLink?.minimumHoldSeconds = 2
        default: manifest.entries[0].duration = 0
        }
        await #expect(throws: StoryboardPreviewError.unresolvedTiming) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test func partialMeasuredVisualCoverageIsRefused() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        plan.shots.removeLast()
        await #expect(throws: StoryboardPreviewError.renderIncomplete) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["overlapping links", "offset narration", "out-of-order links"])
    func measuredRangesMustRemainSequentialFromFrameZero(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        plan.shots[0].sourceStartSeconds = nil
        plan.shots[0].sourceEndSeconds = nil
        switch failure {
        case "overlapping links": plan.shots[0].narrationLink?.lastBeatId = "second-beat"
        case "offset narration": plan.narration?.startFrame = 1
        default:
            plan.shots[0].narrationLink?.firstBeatId = "second-beat"
            plan.shots[0].narrationLink?.lastBeatId = "second-beat"
        }
        await #expect(throws: StoryboardPreviewError.unsupportedLayout) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["identity bytes", "URL", "timing", "audio identity", "audio duration", "transform"])
    func keyCapturesRenderInputsOutsideStoryboardRevision(change: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        plan.shots[0].sourceStartSeconds = nil
        plan.shots[0].sourceEndSeconds = nil
        let first = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        var transforms: [String: Transform] = [:]
        switch change {
        case "identity bytes":
            manifest.entries[0].inputIdentity = .init(contentSHA256: String(repeating: "b", count: 64), byteCount: 101)
        case "URL": manifest.entries[0].source = .external(absolutePath: "/preview-fixture/replacement.mov")
        case "timing": plan.narrationTiming?.anchors[1].speechStart = try NarrationTime(CMTime(value: 7, timescale: 4))
        case "audio identity":
            let hash = String(repeating: "d", count: 64)
            plan.narrationTiming?.sourceFingerprint = hash
            manifest.entries[2].inputIdentity = .init(contentSHA256: hash, byteCount: 201)
        case "audio duration":
            plan.narrationTiming?.duration = try NarrationTime(CMTime(value: 4, timescale: 1))
            manifest.entries[2].duration = 4
        default: transforms["video"] = Transform(width: 0.8, height: 0.8)
        }
        let second = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil, transforms: transforms)
        #expect(first.report.revision == second.report.revision)
        #expect(first.key != second.key)
        #expect(first.key.count == 64 && second.key.count == 64)
    }

    @Test func keyIsDeterministicAcrossManifestOrdering() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs(measured: true)
        let first = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        manifest.entries.reverse()
        let second = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        #expect(first.key == second.key)
        #expect(first.timeline == second.timeline)
    }

    @Test func projectSourcesUseImmutableExpectedURLMap() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        manifest.entries[0].source = .project(relativePath: "media/video.mov")
        let projectURL = URL(fileURLWithPath: "/preview-fixture/project.palmier")
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: projectURL)
        let urls = MediaResolver.expectedURLMap(entries: manifest.entries, projectURL: projectURL)
        #expect(snapshot.sources.allSatisfy { $0.url == urls[$0.mediaRef] })
    }

    @Test(arguments: [1, 30, 120])
    func previewDurationLimitIsInclusive(fps: Int) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        plan.fps = fps
        plan.shots = [.init(id: "still", title: "Still", startFrame: 0, endFrame: 1_800 * plan.fps, mediaRef: "image")]
        let snapshot = try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        #expect(snapshot.frameCount == 1_800 * fps)
        plan.shots[0].endFrame += 1
        await #expect(throws: StoryboardPreviewError.tooLong) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test(arguments: ["fps", "width", "height", "transform"])
    func unsupportedGeometryIsRefusedBeforeArithmetic(failure: String) async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        var transforms: [String: Transform] = [:]
        switch failure {
        case "fps": plan.fps = Int.max
        case "width": plan.width = 0
        case "height": plan.height = Int.max
        default: transforms["video"] = Transform(width: .infinity)
        }
        await #expect(throws: StoryboardPreviewError.unsupportedLayout) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil, transforms: transforms)
        }
    }

    @Test func emptyStoryboardIsRefused() async throws {
        var (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        plan.shots = []
        await #expect(throws: StoryboardPreviewError.emptyStoryboard) {
            try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
    }

    @Test func cancellationBeforeResolutionReturnsStableCancellationError() async throws {
        let (plan, manifest) = try StoryboardPreviewFixtures.inputs()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StoryboardPreviewSnapshot.make(plan: plan, manifest: manifest, projectURL: nil)
        }
        await #expect(throws: StoryboardPreviewError.canceled) { try await operation.value }
    }
}
