import Foundation
import Testing
@testable import CompositorPro

@Suite("Visual source occurrence audit")
struct VisualUniquenessTests {
    private func clip(_ id: String, media: String = "source", start: Int = 0, duration: Int = 30,
                      trim: Int = 0, type: ClipType = .video) -> Clip {
        Clip(id: id, mediaRef: media, mediaType: type, sourceClipType: type,
             startFrame: start, durationFrames: duration, trimStartFrame: trim)
    }

    private func entry(_ id: String = "source", digest: String = "a", origin: MediaImportOrigin? = nil,
                       type: ClipType = .video) -> MediaManifestEntry {
        var entry = MediaManifestEntry(id: id, name: id, type: type, source: .external(absolutePath: "/fixture/\(id)"), duration: 10)
        entry.inputIdentity = MediaInputIdentity(contentSHA256: String(repeating: digest, count: 64), byteCount: 100)
        if let origin { entry.importInput = MediaImportInput(origin: origin) }
        return entry
    }

    private func audit(_ tracks: [Track], media: [MediaManifestEntry]? = nil,
                       nested: [Timeline] = []) async throws -> VisualUniquenessReport {
        let timeline = Timeline(id: "root", tracks: tracks)
        var manifest = MediaManifest()
        manifest.entries = media ?? [entry()]
        return try await VisualUniqueness.audit(timeline: timeline, timelines: [timeline] + nested,
                                                manifest: manifest)
    }

    @Test(arguments: [0, 60])
    func disjointAndSimultaneousUsesConflict(secondStart: Int) async throws {
        let report = try await audit([
            Track(type: .video, clips: [clip("first")]),
            Track(type: .video, clips: [clip("second", start: secondStart, trim: 120)]),
        ])
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.occurrences.count == 2)
        #expect(!report.knownIdentityReuseFree)
    }

    @Test func continuousSplitIsOneOccurrenceButReplayIsNot() async throws {
        let first = clip("first")
        let continuous = clip("second", start: 30, trim: 30)
        let joined = try await audit([Track(type: .video, clips: [continuous, first])])
        #expect(joined.knownIdentityReuseFree)
        #expect(joined.occurrences.first?.clipIds == ["first", "second"])
        #expect(joined.occurrences.first?.endFrame == 60)
        let replay = try await audit([Track(type: .video, clips: [first, clip("second", start: 30)])])
        #expect(replay.conflicts.count == 1)
    }

    @Test func continuousImageSplitPassesButLaterReturnConflicts() async throws {
        let report = try await audit([Track(type: .video, clips: [
            clip("first", type: .image), clip("split", start: 30, type: .image), clip("return", start: 90, type: .image),
        ])], media: [entry(type: .image)])
        #expect(report.occurrences.count == 2)
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.occurrences.first?.clipIds == ["first", "split"])
    }

    @Test(arguments: [false, true])
    func authoredSelectionsRemainDistinctEvenWhenAdjacent(isImage: Bool) async throws {
        let selections = [
            VisualOccurrence(mediaRef: "source", clipIds: ["first"], lane: ["storyboard"], startFrame: 0, endFrame: 30,
                             sourceStart: 0, sourceEnd: isImage ? 0 : 30, isImage: isImage),
            VisualOccurrence(mediaRef: "source", clipIds: ["second"], lane: ["storyboard"], startFrame: 30, endFrame: 60,
                             sourceStart: isImage ? 0 : 30, sourceEnd: isImage ? 0 : 60, isImage: isImage),
        ]
        var manifest = MediaManifest()
        manifest.entries = [entry(type: isImage ? .image : .video)]
        let report = try await VisualUniqueness.audit(occurrences: selections, manifest: manifest)
        #expect(report.occurrences == selections)
        #expect(report.conflicts.first?.occurrences == selections)
        #expect(!report.knownIdentityReuseFree)
    }

    @Test func aliasesConnectHashesAndAlternateProviderRenditionsTransitively() async throws {
        let origin = MediaImportOrigin(provider: "pexels", assetId: "pexels-video-42", landingPageURL: nil)
        let report = try await audit([Track(type: .video, clips: [
            clip("first", media: "one"), clip("second", media: "two", start: 60), clip("third", media: "three", start: 120),
        ])], media: [entry("one", origin: origin), entry("two", digest: "b", origin: origin), entry("three", digest: "b")])
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.occurrences.count == 3)
        #expect(report.conflicts.first?.sourceIds.contains(origin.sourceId) == true)
    }

    @Test func distinctBytesPassIdentityCheckWithoutCertifyingDelivery() async throws {
        let report = try await audit([Track(type: .video, clips: [clip("first"), clip("other", media: "other", start: 30)])],
                                     media: [entry(), entry("other", digest: "b")])
        #expect(report.knownIdentityReuseFree)
        #expect(report.receipt["deliveryVerified"] as? Bool == false)
        #expect(report.receipt["identityFreshness"] as? String == "not_checked")
        #expect(report.receipt["perceptualSimilarity"] as? String == "not_checked")
        #expect(report.receipt["faceInspection"] as? String == "not_checked")
    }

    @Test func hiddenTracksAndLinkedAudioDoNotCountAsVisualUses() async throws {
        let report = try await audit([
            Track(type: .video, clips: [clip("visible")]),
            Track(type: .video, hidden: true, clips: [clip("hidden")]),
            Track(type: .audio, clips: [clip("linked", type: .audio)]),
        ])
        #expect(report.knownIdentityReuseFree)
        #expect(report.occurrences.count == 1)
    }

    @Test func retainedUnknownIdentityRemainsUnresolvedAndRepeatedRefStillConflicts() async throws {
        var unknown = entry()
        unknown.inputIdentity = nil
        let report = try await audit([Track(type: .video, clips: [clip("first"), clip("second", start: 60)])], media: [unknown])
        #expect(report.unresolved.map(\.reason) == ["missing_content_identity"])
        #expect(report.conflicts.count == 1)
        #expect(!report.knownIdentityReuseFree)
    }

    @Test func unknownLottieInputsRemainUnresolved() async throws {
        let report = try await audit([Track(type: .video, clips: [clip("animation", type: .lottie)])],
                                     media: [entry(type: .lottie)])
        #expect(report.unresolved.map(\.reason) == ["unresolved_derivative_lineage"])
    }

    @Test func repeatedNestedCarriersExposeDistinctRootFrameOccurrences() async throws {
        let child = Timeline(id: "child", tracks: [Track(id: "child-lane", type: .video, clips: [clip("visual")])])
        let report = try await audit([Track(type: .video, clips: [
            clip("nest-one", media: child.id, type: .sequence),
            clip("nest-two", media: child.id, start: 90, type: .sequence),
        ])], nested: [child])
        #expect(report.conflicts.count == 1)
        let occurrences = try #require(report.conflicts.first?.occurrences)
        #expect(occurrences.map(\.startFrame) == [0, 90])
        #expect(occurrences.map(\.clipIds) == [["nest-one/visual"], ["nest-two/visual"]])
    }

    @Test func trimmedNestedContinuousCarriersCoalesceUsingStableChildLane() async throws {
        let child = Timeline(id: "child", tracks: [
            Track(id: "early-overlay", type: .video, clips: [clip("other", media: "other", duration: 10)]),
            Track(id: "main-lane", type: .video, clips: [clip("visual", duration: 60)]),
        ])
        let report = try await audit([Track(type: .video, clips: [
            clip("nest-one", media: child.id, type: .sequence),
            clip("nest-two", media: child.id, start: 30, trim: 30, type: .sequence),
        ])], media: [entry(), entry("other", digest: "b")], nested: [child])
        #expect(report.knownIdentityReuseFree)
        #expect(report.occurrences.count == 2)
        #expect(report.occurrences.first { $0.mediaRef == "source" }?.clipIds.count == 2)
    }

    @Test func nestedCycleIsUnresolvedInsteadOfRecursing() async throws {
        let child = Timeline(id: "child", tracks: [Track(type: .video, clips: [clip("cycle", media: "root", type: .sequence)])])
        let report = try await audit([Track(type: .video, clips: [clip("nest", media: child.id, type: .sequence)])], nested: [child])
        #expect(report.unresolved.map(\.reason) == ["cyclic_or_excessive_nesting"])
    }

    @Test func missingNestedTimelineAndMissingMediaAreUnresolved() async throws {
        let report = try await audit([Track(type: .video, clips: [
            clip("missing-nest", media: "missing-timeline", type: .sequence),
            clip("missing-media", media: "missing-file", start: 60),
        ])])
        #expect(Set(report.unresolved.map(\.reason)) == ["missing_nested_timeline", "missing_media"])
        #expect(!report.knownIdentityReuseFree)
    }

    @Test func nestedOverlaysCannotHideRepeatedInputs() async throws {
        let inner = Timeline(id: "inner", tracks: [Track(type: .video, clips: [clip("inside")])])
        let outer = Timeline(id: "outer", tracks: [
            Track(type: .video, clips: [clip("nested", media: inner.id, type: .sequence)]),
            Track(type: .video, clips: [clip("overlay")]),
        ])
        let report = try await audit([Track(type: .video, clips: [clip("carrier", media: outer.id, start: 90, type: .sequence)])],
                                     nested: [inner, outer])
        #expect(report.conflicts.count == 1)
        #expect(report.conflicts.first?.occurrences.map(\.startFrame) == [90, 90])
        #expect(Set(report.occurrences.flatMap(\.clipIds)) == ["carrier/nested/inside", "carrier/overlay"])
    }

    @Test func duplicatePlacementIDsRemainUnresolved() async throws {
        let report = try await audit([Track(type: .video, clips: [clip("same"), clip("same", start: 60)])])
        #expect(report.unresolved.map(\.reason) == ["duplicate_clip_id"])
        #expect(!report.knownIdentityReuseFree)
    }

    @Test(arguments: [Int.min, -1, Int.max])
    func invalidNestedTrimDoesNotReachUncheckedFlattenerArithmetic(trim: Int) async throws {
        let child = Timeline(id: "child", tracks: [Track(type: .video, clips: [clip("inside")])])
        let report = try await audit([Track(type: .video, clips: [clip("carrier", media: child.id, trim: trim, type: .sequence)])],
                                     nested: [child])
        #expect(report.unresolved.map(\.reason) == ["invalid_clip_timing"])
    }

    @Test func manyContinuousSplitsRetainOneOccurrenceAndAllPlacementIDs() async throws {
        let clips = (0..<10_000).map { clip("split-\($0)", start: $0 * 30, trim: $0 * 30) }
        let report = try await audit([Track(type: .video, clips: clips)])
        #expect(report.knownIdentityReuseFree)
        #expect(report.occurrences.count == 1)
        #expect(report.occurrences.first?.clipIds.count == clips.count)
        #expect(report.occurrences.first?.endFrame == 300_000)
    }

    @Test(arguments: [Int.min, -1, 0, Int.max])
    func invalidDurationsDoNotTrap(duration: Int) async throws {
        let report = try await audit([Track(type: .video, clips: [clip("invalid", duration: duration)])])
        #expect(report.unresolved.map(\.reason) == ["invalid_clip_timing"])
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 0, 1001])
    func invalidSpeedsRemainUnresolved(speed: Double) async throws {
        var invalid = clip("invalid")
        invalid.speed = speed
        let report = try await audit([Track(type: .video, clips: [invalid])])
        #expect(report.unresolved.map(\.reason) == ["invalid_clip_timing"])
    }

    @Test func cancellationDoesNotReturnSuccessfulReport() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await audit([])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: ["timeline", "manifest", "selection", "project", "cancel"])
    @MainActor func changedStateRejectsCompletedSnapshot(change: String) async throws {
        let editor = EditorViewModel()
        let ready = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = Task {
            try await editor.visualUniquenessReport { _, _, _ in
                ready.continuation.yield(())
                for await _ in release.stream { break }
                return VisualUniquenessReport()
            }
        }
        for await _ in ready.stream { break }
        switch change {
        case "timeline": editor.timeline.name = "Changed"
        case "manifest": editor.mediaManifest.entries.append(entry())
        case "selection": editor.activeTimelineId = "other"
        case "project": editor.projectURL = URL(fileURLWithPath: "/changed/project.compositorpro")
        default: task.cancel()
        }
        release.continuation.yield(())
        if change == "cancel" {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: VisualUniquenessValidationError.self) { try await task.value }
        }
        ready.continuation.finish()
        release.continuation.finish()
    }
}
