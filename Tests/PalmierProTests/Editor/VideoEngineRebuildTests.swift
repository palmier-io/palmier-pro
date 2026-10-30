import Foundation
import Testing
@testable import PalmierPro

@Suite("VideoEngine — rebuild cache", .serialized)
@MainActor
struct VideoEngineRebuildTests {
    @Test func emptyTimelineRebuildCacheHitDoesNotRecurse() async throws {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [])
        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }

        engine.rebuild()
        try await #require(engine.rebuildTask).value

        engine.rebuild()
        #expect(engine.rebuildTask == nil)
    }
}
