import Foundation
import Testing
@testable import CompositorPro

@Suite("Silence detection and caching")
struct SilenceDetectorTests {
    @Test func segmentDurationCalculatesCorrectly() {
        let seg = SilenceDetector.Segment(startSeconds: 1.5, endSeconds: 4.0)
        #expect(seg.durationSeconds == 2.5)

        let inverted = SilenceDetector.Segment(startSeconds: 5.0, endSeconds: 3.0)
        #expect(inverted.durationSeconds == 0)
    }

    @Test func rejectsInvalidDetectionParameters() async {
        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent.wav")

        await #expect(throws: SilenceDetector.DetectionError.invalidParameters) {
            _ = try await SilenceDetector.detectSilentSegments(
                in: dummyURL,
                thresholdDb: .nan,
                minSilenceDuration: 0.5,
                paddingSeconds: 0.1
            )
        }

        await #expect(throws: SilenceDetector.DetectionError.invalidParameters) {
            _ = try await SilenceDetector.detectSilentSegments(
                in: dummyURL,
                thresholdDb: -30,
                minSilenceDuration: -1.0,
                paddingSeconds: 0.1
            )
        }

        await #expect(throws: SilenceDetector.DetectionError.invalidParameters) {
            _ = try await SilenceDetector.detectSilentSegments(
                in: dummyURL,
                thresholdDb: -30,
                minSilenceDuration: 0.5,
                paddingSeconds: -0.5
            )
        }
    }

    @Test @MainActor func silenceStoreKeysOnSourceAndInvalidatesByAsset() {
        let store = SilenceStore()
        let settings = SilenceDetectionSettings(thresholdDb: -35.0, minSilenceDuration: 0.5, paddingSeconds: 0.1)!
        let key = silenceCacheKey(sourceIdentity: "file-a|rev-1", settings: settings)
        #expect(key == "file-a|rev-1|-35.0|0.5|0.1")

        let expected = [SilenceDetector.Segment(startSeconds: 1.0, endSeconds: 3.0)]
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings) == nil)

        store.install(expected, mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings)
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings) == expected)
        // A relink changes the source identity, so the previous decode is not served.
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-2", settings: settings) == nil)

        // Invalidating an asset drops every settings variant, not just one.
        let other = SilenceDetectionSettings(thresholdDb: -25.0, minSilenceDuration: 1.0, paddingSeconds: 0.2)!
        store.install(expected, mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: other)
        store.invalidate(mediaRef: "asset1")
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings) == nil)
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: other) == nil)

        store.install(expected, mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings)
        store.reset()
        #expect(store.segments(mediaRef: "asset1", sourceIdentity: "file-a|rev-1", settings: settings) == nil)
    }

    @Test @MainActor func sourceIdentityChangesWhenAssetIsRepointed() {
        let asset = MediaAsset(
            id: "asset1", url: URL(fileURLWithPath: "/tmp/first.wav"), type: .audio, name: "One", duration: 1
        )
        let first = asset.sourceIdentity
        asset.url = URL(fileURLWithPath: "/tmp/second.wav")
        #expect(asset.sourceIdentity != first)
        #expect(asset.sourceIdentity.contains("second.wav"))
    }

    @Test func silenceDetectionSettingsValidation() {
        let valid = SilenceDetectionSettings(thresholdDb: -35.0, minSilenceDuration: 0.5, paddingSeconds: 0.1)
        #expect(valid != nil)
        #expect(valid?.thresholdDb == -35.0)

        let tooLoud = SilenceDetectionSettings(thresholdDb: -10.0, minSilenceDuration: 0.5, paddingSeconds: 0.1)
        #expect(tooLoud == nil)

        let tooQuiet = SilenceDetectionSettings(thresholdDb: -90.0, minSilenceDuration: 0.5, paddingSeconds: 0.1)
        #expect(tooQuiet == nil)

        let durationTooShort = SilenceDetectionSettings(thresholdDb: -35.0, minSilenceDuration: 0.05, paddingSeconds: 0.1)
        #expect(durationTooShort == nil)

        let paddingTooLong = SilenceDetectionSettings(thresholdDb: -35.0, minSilenceDuration: 0.5, paddingSeconds: 3.0)
        #expect(paddingTooLong == nil)
    }
}

