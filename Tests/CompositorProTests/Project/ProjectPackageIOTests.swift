import Foundation
import Testing
@testable import CompositorPro

@Suite("Project package I/O executor")
struct ProjectPackageIOTests {
    /// LUT import and every other package install ride this executor, so the operation must not
    /// run on the main thread even when the caller is main-actor isolated.
    @Test func performRunsTheOperationOffTheMainThread() async throws {
        let io = ProjectPackageIO()
        let isMain = try await io.perform { Thread.isMainThread }
        #expect(!isMain)
    }
}
