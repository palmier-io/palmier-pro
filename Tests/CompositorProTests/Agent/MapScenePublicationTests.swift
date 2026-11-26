import AppKit
import Foundation
import Testing
@testable import CompositorPro

@MainActor
private final class MapPublicationGate {
    let entered = PackageTestSignal()
    let release = PackageTestSignal()
    private(set) var stage: URL?

    func hold(_ output: MapSceneRenderOutput) async {
        stage = output.stage
        entered.signal()
        await release.wait()
    }
}

@Suite("Map publication lifecycle", .serialized)
@MainActor
struct MapScenePublicationTests {
    @Test(arguments: ["cancellation", "configuration", "timeline", "image"])
    func staleOrCancelledRenderCleansStageAndLeavesEditingStateUntouched(change: String) async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let imageURL = try await fixture.stage(MediaInputIdentityFixtures.imageData())
            let image = MediaAsset(url: imageURL, type: .image, name: "Source")
            editor.importMediaAsset(image)
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let gate = MapPublicationGate()
            let input = MapSceneInput(places: [.init(name: "Penang")], durationFrames: 4, width: 480, height: 270,
                objects: [.init(id: "source", kind: .image, place: "Penang", imageMediaRef: image.id)], palette: plainPalette())
            let task = Task {
                try await editor.prepareMapScene(input, addToTimeline: true, render: { spec, atlas, sources, reusable in
                    let output = try await MapSceneRenderer.render(spec, atlas: atlas, sources: sources, reusable: reusable)
                    await gate.hold(output)
                    return output
                })
            }
            await gate.entered.wait()
            switch change {
            case "cancellation": task.cancel()
            case "configuration": editor.timeline.fps = 60
            case "timeline": editor.timeline = Fixtures.timeline()
            case "image": image.url = fixture.root.appendingPathComponent("repointed.png")
            default: Issue.record("Unexpected test input")
            }
            let expected = editor.timeline
            let expectedManifest = editor.mediaManifest
            gate.release.signal()
            let result = await task.result
            if case .success = result { Issue.record("Stale/cancelled scene unexpectedly published") }
            #expect(editor.timeline == expected)
            #expect(editor.mediaManifest == expectedManifest)
            #expect(editor.mediaAssets.map(\.id) == [image.id])
            #expect(!undo.canUndo)
            let stage = try #require(gate.stage)
            #expect(try await fixture.exists(stage) == false)
        }
    }

    @Test func editsMadeDuringRenderingSurviveTheMapUndo() async throws {
        try await withSavedMediaPackageTestFixture { _, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let gate = MapPublicationGate()
            let input = MapSceneInput(places: [.init(name: "Penang")], durationFrames: 4, width: 480, height: 270, palette: plainPalette())
            let task = Task {
                try await editor.prepareMapScene(input, addToTimeline: true, render: { spec, atlas, sources, reusable in
                    let output = try await MapSceneRenderer.render(spec, atlas: atlas, sources: sources, reusable: reusable)
                    await gate.hold(output)
                    return output
                })
            }
            await gate.entered.wait()
            editor.timeline.tracks[0].clips = [Fixtures.clip(id: "manual", start: 0, duration: 30)]
            editor.selectedClipIds = ["manual"]
            let expected = editor.timeline
            gate.release.signal()
            let result = try await task.value
            #expect(result.changed)
            #expect(editor.timeline.tracks.flatMap(\.clips).contains { $0.id == "manual" })
            undo.undo()
            #expect(editor.timeline == expected)
            #expect(editor.selectedClipIds == ["manual"])
            #expect(editor.mediaAssets.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    private func plainPalette() -> MapScenePalette {
        var value = MapScenePalette()
        value.relief = false
        return value
    }
}
