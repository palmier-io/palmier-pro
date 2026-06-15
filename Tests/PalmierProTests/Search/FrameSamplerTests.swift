import Foundation
import Testing
@testable import PalmierPro

@Suite("FrameSampler")
struct FrameSamplerTests {
    @Test func detectsScenesAndHonorsCoverageFloor() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 10),
            .init(rgb: (30, 200, 30), seconds: 10),
            .init(rgb: (30, 30, 220), seconds: 10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var frames: [FrameSampler.Frame] = []
        for try await frame in FrameSampler.frames(url: url, duration: 30) {
            frames.append(frame)
        }

        let shotStarts = frames.filter(\.isNewShot).map(\.time)
        #expect(shotStarts.count == 3, "expected 3 scenes, got starts at \(shotStarts)")
        #expect(frames.first?.isNewShot == true)

        // Scene boundaries land within one candidate interval of 10s and 20s.
        #expect(shotStarts.dropFirst().allSatisfy { t in
            abs(t - 10) <= 2.5 || abs(t - 20) <= 2.5
        })

        // Coverage floor: a 10s static shot keeps at least one non-boundary frame.
        #expect(frames.count > shotStarts.count)
        // Monotonic, no duplicates.
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func shortClipGetsOneMidpointSample() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (220, 30, 30), seconds: 0.6)])
        defer { try? FileManager.default.removeItem(at: url) }

        var frames: [FrameSampler.Frame] = []
        for try await frame in FrameSampler.frames(url: url, duration: 0.6) {
            frames.append(frame)
        }
        #expect(frames.count == 1)
        #expect(frames.first?.isNewShot == true)
    }
}
