import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Map scene geography")
struct MapSceneTests {
    @Test func catalogResolvesAliasesAndRejectsUnknownOrAmbiguous() throws {
        #expect(try MalaysiaPlaceCatalog.resolve("George Town").canonicalName == "Penang")
        #expect(try MalaysiaPlaceCatalog.resolve("kl").canonicalName == "Kuala Lumpur")
        #expect(throws: MapSceneError.unresolvedPlace(name: "Springfield")) {
            try MalaysiaPlaceCatalog.resolve("Springfield")
        }
        #expect(throws: MapSceneError.unresolvedPlace(name: "   ")) {
            try MalaysiaPlaceCatalog.resolve("   ")
        }
    }

    @Test func equirectangularProjectionKeepsRelativeGeometry() throws {
        let spec = try MapSceneSpec.validated(
            MapSceneInput(
                places: [MapScenePlace(name: "Penang"), MapScenePlace(name: "Kulim")],
                connections: nil, camera: nil, durationFrames: 120, width: 960, height: 540
            ), defaultWidth: 960, defaultHeight: 540
        )
        let frame = MapProjection.frame(for: spec)
        #expect(frame.points.count == 2)
        // Penang (west) sits left of Kulim (east); both on camera center render at canvas center.
        #expect(frame.points[0].x < frame.points[1].x)
        let camera = MapSceneCameraRequest(frame: 0, center: try MalaysiaPlaceCatalog.resolve("Penang"), zoom: 1)
        let penangScreen = MapProjection.screen(frame.points[0], camera: camera, in: frame)
        #expect(abs(penangScreen.x - frame.center.x) < 0.01)
        #expect(abs(penangScreen.y - frame.center.y) < 0.01)
        let kulimScreen = MapProjection.screen(frame.points[1], camera: camera, in: frame)
        #expect(kulimScreen.x > penangScreen.x)
    }

    @Test func validationRejectsDuplicateUnknownAndUnevidencedLinks() throws {
        #expect(throws: MapSceneError.duplicatePlace(name: "George Town")) {
            try MapSceneSpec.validated(
                MapSceneInput(places: [MapScenePlace(name: "Penang"), MapScenePlace(name: "George Town")],
                              connections: nil, camera: nil, durationFrames: 120, width: 960, height: 540),
                defaultWidth: 960, defaultHeight: 540)
        }
        #expect(throws: MapSceneError.unresolvedPlace(name: "Nowhere")) {
            try MapSceneSpec.validated(
                MapSceneInput(places: [MapScenePlace(name: "Nowhere")],
                              connections: nil, camera: nil, durationFrames: 120, width: 960, height: 540),
                defaultWidth: 960, defaultHeight: 540)
        }
        #expect(throws: MapSceneError.connectionNeedsClaims(from: "Penang", to: "Kulim")) {
            try MapSceneSpec.validated(
                MapSceneInput(
                    places: [MapScenePlace(name: "Penang"), MapScenePlace(name: "Kulim")],
                    connections: [MapSceneConnection(from: "Penang", to: "Kulim", kind: "sourced", claimIds: nil, revealFrame: nil)],
                    camera: nil, durationFrames: 120, width: 960, height: 540),
                defaultWidth: 960, defaultHeight: 540)
        }
    }

    @Test func invalidFrameAndZoomRefuseBeforeMutation() throws {
        #expect(throws: MapSceneError.invalidFrame) {
            try MapSceneSpec.validated(
                MapSceneInput(places: [MapScenePlace(name: "Penang")], connections: nil,
                              camera: [MapSceneCameraKey(frame: 999, place: "Penang", zoom: nil)],
                              durationFrames: 120, width: 960, height: 540),
                defaultWidth: 960, defaultHeight: 540)
        }
        #expect(throws: MapSceneError.invalidZoom) {
            try MapSceneSpec.validated(
                MapSceneInput(places: [MapScenePlace(name: "Penang")], connections: nil,
                              camera: [MapSceneCameraKey(frame: 0, place: "Penang", zoom: 9)],
                              durationFrames: 120, width: 960, height: 540),
                defaultWidth: 960, defaultHeight: 540)
        }
    }

    @Test func lottieCarriesBodymovinSignatureAndAttachedLabels() throws {
        let spec = try MapSceneSpec.validated(
            MapSceneInput(
                places: [MapScenePlace(name: "Penang"), MapScenePlace(name: "Kulim")],
                connections: [MapSceneConnection(from: "Penang", to: "Kulim", kind: "illustrative", claimIds: nil, revealFrame: nil)],
                camera: [MapSceneCameraKey(frame: 0, place: "Kuala Lumpur", zoom: 1),
                         MapSceneCameraKey(frame: 60, place: "Penang", zoom: 3)],
                durationFrames: 90, width: 480, height: 270),
            defaultWidth: 480, defaultHeight: 270)
        let json = MapSceneLottie.json(for: spec)
        #expect(json["v"] as? String == "5.7.0")
        #expect(json["fr"] as? Int == 30)
        #expect(json["op"] as? Int == 90)
        let layers = try #require(json["layers"] as? [[String: Any]])
        let labels = layers.filter { ($0["ty"] as? Int) == 5 }
        #expect(labels.count == 2)
        #expect(labels.allSatisfy { ($0["parent"] as? Int) == 1 })
        let text = try MapSceneLottie.data(for: spec)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-scene-\(UUID().uuidString).json")
        try text.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LottieVideoGenerator.isLottie(at: url))
    }
}

@Suite("Map scene MCP")
@MainActor
struct MapSceneMCPTests {
    @Test func buildRegistersLibraryAssetAndPlacesOnRequest() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let executor = ToolExecutor(editor: editor)
            let result = await executor.execute(name: "build_map_scene", args: [
                "places": [["name": "Penang"], ["name": "Kulim"]],
                "connections": [["from": "Penang", "to": "Kulim", "kind": "illustrative"]],
                "camera": [["frame": 0, "place": "Penang", "zoom": 0.5]],
                "durationFrames": 60,
                "width": 480,
                "height": 270,
                "addToTimeline": true,
            ])
            #expect(!result.isError, "\(ToolHarness.textOf(result))")
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
            let mediaRef = try #require(receipt["mediaRef"] as? String)
            let asset = try #require(editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) })
            #expect(asset.type == .video)
            let spec = try #require(receipt["spec"] as? [String: Any])
            #expect((spec["places"] as? [[String: Any]])?.first?["name"] as? String == "Penang")
            let placed = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == asset.id }
            #expect(placed.count == 1)
            #expect(placed.first?.durationFrames == 60)
            undo.undo()
            #expect(editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == mediaRef }.isEmpty)
        }
    }

    @Test func unknownPlaceRefusesWithoutLibraryChange() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let undo = UndoManager()
            editor.undo.attach(undo)
            let before = editor.mediaAssets.count
            let result = await ToolExecutor(editor: editor).execute(name: "build_map_scene", args: [
                "places": [["name": "Atlantis"]],
            ])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("not in the map catalog"))
            #expect(editor.mediaAssets.count == before)
            #expect(!undo.canUndo)
        }
    }
}

@Suite("Map scene label attachment")
struct MapSceneAttachmentTests {
    /// Renders the same spec at the first and last camera keys and checks that a
    /// light (label) pixel follows the projected pin position — labels and pins
    /// share the camera transform instead of drifting.
    @Test @MainActor func labelFollowsCameraTransform() async throws {
        let spec = try MapSceneSpec.validated(
            MapSceneInput(
                places: [MapScenePlace(name: "Penang"), MapScenePlace(name: "Kulim")],
                connections: nil,
                camera: [MapSceneCameraKey(frame: 0, place: "Penang", zoom: 0.5),
                         MapSceneCameraKey(frame: 60, place: "Kulim", zoom: 0.5)],
                durationFrames: 90, width: 960, height: 540),
            defaultWidth: 960, defaultHeight: 540)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-attach-\(UUID().uuidString).json")
        try MapSceneLottie.data(for: spec).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = CGSize(width: 960, height: 540)
        let view = try await LottieVideoGenerator.loadView(forFileAt: url, target: target)
        let frame = MapProjection.frame(for: spec)
        let shot0 = try #require(LottieVideoGenerator.renderFrame(view: view, frame: 0, target: target))
        let shotEnd = try #require(LottieVideoGenerator.renderFrame(view: view, frame: 89, target: target))
        for (index, place) in spec.places.enumerated() {
            let plane = frame.points[index]
            let start = MapProjection.screen(plane, camera: spec.camera[0], in: frame)
            let end = MapProjection.screen(plane, camera: spec.camera[1], in: frame)
            #expect(start != end, "camera move must change \(place.place.canonicalName) screen position")
            #expect(brightPixelCount(in: shot0, near: start, radius: 24) > 0,
                    "\(place.label) label must render near its pin at frame 0")
            #expect(brightPixelCount(in: shotEnd, near: end, radius: 24) > 0,
                    "\(place.label) label must follow the camera at frame 89")
        }

    }

    private func brightPixelCount(in image: CGImage, near point: CGPoint, radius: Int) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var bright = 0
        let x = Int(point.x), y = Int(point.y)
        for px in stride(from: max(0, x - radius), through: min(image.width - 1, x + radius), by: 2) {
            for py in stride(from: max(0, y - radius), through: min(image.height - 1, y + radius), by: 2) {
                guard let color = rep.colorAt(x: px, y: py) else { continue }
                if color.redComponent > 0.7, color.greenComponent > 0.7, color.blueComponent > 0.7 { bright += 1 }
            }
        }
        return bright
    }
}
