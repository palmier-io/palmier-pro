import Foundation
import Testing
@testable import PalmierPro

@Suite("SceneDetector")
struct SceneDetectorTests {
    @Test func hardCutsLandAtSceneBoundaries() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 2),
            .init(rgb: (30, 200, 30), seconds: 2),
            .init(rgb: (30, 30, 220), seconds: 2),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await SceneDetector.detect(in: url)
        #expect(analysis.cuts.count == 2)
        #expect(abs(analysis.cuts[0] - 2) < 0.25, "first cut at \(analysis.cuts[0])")
        #expect(abs(analysis.cuts[1] - 4) < 0.25, "second cut at \(analysis.cuts[1])")
        #expect(analysis.scenes.count == 3)
        #expect(analysis.scenes.first?.start == 0)
        #expect(abs((analysis.scenes.last?.end ?? 0) - analysis.duration) < 0.01)
    }

    @Test func staticClipHasNoCuts() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 3),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await SceneDetector.detect(in: url)
        #expect(analysis.cuts.isEmpty)
        #expect(analysis.scenes.count == 1)
    }

    @Test func minimumSceneDurationSkipsRapidFlicker() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 0.2),
            .init(rgb: (30, 200, 30), seconds: 0.2),
            .init(rgb: (220, 30, 30), seconds: 0.2),
            .init(rgb: (30, 200, 30), seconds: 0.2),
            .init(rgb: (220, 30, 30), seconds: 0.2),
            .init(rgb: (30, 200, 30), seconds: 2),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let analysis = try await SceneDetector.detect(in: url)
        #expect(!analysis.cuts.isEmpty)
        let gaps = zip(analysis.cuts.dropFirst(), analysis.cuts).map(-)
        #expect(gaps.allSatisfy { $0 >= SceneDetector.minimumSceneDuration - 0.05 })
    }

    @Test func sceneRangesIgnoreInvalidCuts() {
        let analysis = SceneAnalysis(cuts: [-1, 0, 2, 4, 10], duration: 6)
        let scenes = analysis.scenes
        #expect(scenes.count == 3)
        #expect(scenes[0].start == 0 && scenes[0].end == 2)
        #expect(scenes[1].start == 2 && scenes[1].end == 4)
        #expect(scenes[2].start == 4 && scenes[2].end == 6)
    }
}
