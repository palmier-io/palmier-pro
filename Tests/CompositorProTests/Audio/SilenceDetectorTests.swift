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

    @Test @MainActor func silenceStoreCachesAndInvalidates() {
        let store = SilenceStore()
        let key = silenceCacheKey(mediaRef: "asset1", thresholdDb: -35.0, minSilenceDuration: 0.5, paddingSeconds: 0.1)
        #expect(key == "asset1|-35.0|0.5|0.1")

        #expect(store.segments(for: key) == nil)

        let expected = [SilenceDetector.Segment(startSeconds: 1.0, endSeconds: 3.0)]
        store.install(expected, for: key)
        #expect(store.segments(for: key) == expected)

        store.invalidate(key)
        #expect(store.segments(for: key) == nil)

        store.install(expected, for: key)
        store.reset()
        #expect(store.segments(for: key) == nil)
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

