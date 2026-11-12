import Foundation
import Testing
@testable import CompositorPro

@Suite("Edit plan packages")
struct EditPlanPackageTests {
    @Test func plansSurviveAPackageRoundTrip() async throws {
        let plans = [
            EditPlan(
                id: "plan-package",
                name: "Coverage",
                goal: "Illustrate one claim.",
                timelineId: "timeline-package",
                fps: 30,
                width: 1920,
                height: 1080,
                sections: [EditPlanSection(
                    id: "section-package",
                    title: "Hook",
                    summary: "Opening line.",
                    startFrame: 0,
                    endFrame: 90
                )],
                shots: [EditPlanShot(
                    id: "shot-package",
                    title: "Harbor at dusk",
                    startFrame: 0,
                    endFrame: 90,
                    trackId: "track-package",
                    mediaRef: "asset-package"
                )]
            ),
        ]
        let roundTripped = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-plan-package-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try EditPlanStore.writePackageFile(try EditPlanStore.encode(plans), to: directory, sourceURL: nil)
            return try EditPlanStore.readPackageFile(at: directory)
        }.value
        #expect(roundTripped.unreadable == false)
        let decoded = try #require(roundTripped.plans.first)
        #expect(decoded.id == "plan-package")
        #expect(decoded.name == "Coverage")
        #expect(decoded.timelineId == "timeline-package")
        #expect(decoded.sections.map(\.id) == ["section-package"])
        #expect(decoded.shots.map(\.id) == ["shot-package"])
        #expect(abs(decoded.updatedAt.timeIntervalSince(plans[0].updatedAt)) < 1)
    }

    @Test func malformedPlansArePreservedRatherThanReplaced() async throws {
        let outcome = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-plan-malformed-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("not plans".utf8).write(to: directory.appendingPathComponent(Project.plansFilename))
            let read = try EditPlanStore.readPackageFile(at: directory)
            let snapshot = EditPlanStore.snapshot(plans: [], loadFailed: read.unreadable)
            return (read: read, snapshot: snapshot)
        }.value
        #expect(outcome.read.plans.isEmpty)
        #expect(outcome.read.unreadable)
        #expect(outcome.snapshot == nil)
    }

    @Test func plansJoinTheProjectPackageSnapshot() async throws {
        let plans = try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("edit-plan-project-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let timeline = Timeline()
            let project = ProjectFile(
                timelines: [timeline],
                activeTimelineId: timeline.id,
                openTimelineIds: [timeline.id]
            )
            try JSONEncoder().encode(project).write(to: directory.appendingPathComponent(Project.timelineFilename))
            let plan = EditPlan(
                id: "plan-project",
                name: "Coverage",
                timelineId: timeline.id,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height
            )
            try EditPlanStore.writePackageFile(try EditPlanStore.encode([plan]), to: directory, sourceURL: nil)
            return try VideoProject.readProjectPackage(at: directory)
        }.value
        #expect(plans.plansUnreadable == false)
        #expect(plans.plans?.map(\.id) == ["plan-project"])
    }
}
