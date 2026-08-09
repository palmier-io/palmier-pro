import Foundation
import Testing
@testable import PalmierPro

/// Reads Linux-authored `.palmier` fixtures and asserts Swift decode parity.
/// macOS CI owns this suite. The Linux host cannot run Swift.
@Suite("Linux fixture compatibility")
struct LinuxFixtureCompatibilityTests {
    @Test("opens the empty Linux timeline fixture")
    func opensEmptyLinuxTimelineFixture() throws {
        let fixtureURL = try #require(Self.fixtureURL(named: "empty-timeline.palmier"))
        let projectURL = fixtureURL.appendingPathComponent("project.json")
        let data = try Data(contentsOf: projectURL)
        let project = try ProjectFile.decode(data)
        #expect(!project.timelines.isEmpty)
        #expect(project.timelines[0].fps == 30)
        #expect(project.timelines[0].width == 1920)
        #expect(project.timelines[0].height == 1080)
    }

    private static func fixtureURL(named name: String) -> URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("linux/fixtures/projects/linux/\(name)", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("linux/fixtures/projects/linux/\(name)", isDirectory: true),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
