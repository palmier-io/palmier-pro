import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Native map rendering", .serialized)
struct MapSceneRendererTests {
    @Test func realCountryFillAppearsOnlyDuringItsWindowAndSamplesDeterministically() async throws {
        let atlas = try await MapAtlasStore.shared.snapshot()
        let input = MapSceneInput(places: [.init(name: "country:GEO", showPin: false, showLabel: false)],
            durationFrames: 40, width: 480, height: 270,
            regions: [.init(name: "country:GEO", showLabel: false, color: "#EE4422", opacity: 1, revealFrame: 10, endFrame: 30)],
            palette: darkPalette())
        let spec = try MapSceneSpec.validated(input, defaultWidth: 480, defaultHeight: 270, atlas: atlas)
        let before = try await MapSceneRenderer.sample(spec, atlas: atlas, frame: 0)
        let during = try await MapSceneRenderer.sample(spec, atlas: atlas, frame: 22)
        let after = try await MapSceneRenderer.sample(spec, atlas: atlas, frame: 30)
        #expect(redCount(during) > redCount(before) + 1000)
        #expect(after.pixels == before.pixels)
        #expect(try await MapSceneRenderer.sample(spec, atlas: atlas, frame: 22).pixels == during.pixels)
    }

    @Test func geographicBackgroundImageIsNorthUpAndItsBytesAffectTheDigest() async throws {
        try await withPackageTestFixture { fixture in
            let source = try await fixture.stage(twoTonePNG())
            let input = MapSceneInput(places: [.init(name: "center", latitude: 0, longitude: 0, showPin: false, showLabel: false)],
                camera: [.init(frame: 0, zoom: 1, latitude: 0, longitude: 0)], durationFrames: 2, width: 480, height: 270,
                palette: darkPalette(), backgroundImage: .init(mediaRef: "texture", west: -1, south: -2, east: 1, north: 2))
            let spec = try MapSceneSpec.validated(input, defaultWidth: 480, defaultHeight: 270)
            let raster = try await MapSceneRenderer.sample(spec, atlas: .empty, frame: 0, sources: ["texture": source])
            let projection = MapProjection.frame(for: spec)
            let north = MapProjection.screen(MapProjection.point(.init(latitude: 1, longitude: 0), in: projection), camera: spec.camera[0], in: projection)
            let south = MapProjection.screen(MapProjection.point(.init(latitude: -1, longitude: 0), in: projection), camera: spec.camera[0], in: projection)
            #expect(pixel(raster, at: north).r > 200)
            #expect(pixel(raster, at: north).b < 50)
            #expect(pixel(raster, at: south).b > 200)
            let old = try await fixture.io.perform { try MapSceneRenderResources.load(sources: ["texture": source], relief: false).imageDigests }
            let replacement = try await twoTonePNG(swapped: true)
            try await fixture.io.perform { try replacement.write(to: source) }
            let new = try await fixture.io.perform { try MapSceneRenderResources.load(sources: ["texture": source], relief: false).imageDigests }
            #expect(old != new)
        }
    }

    @Test func labelsFollowTheCameraAndStayReadable() async throws {
        let value = try MapSceneSpec.validated(MapSceneInput(places: [
            .init(name: "Penang", label: "WEST", showPin: false), .init(name: "Kulim", label: "EAST", showPin: false),
        ], camera: [.init(frame: 0, place: "Penang", zoom: 0.3), .init(frame: 29, place: "Kulim", zoom: 0.3)],
            durationFrames: 30, width: 480, height: 270, palette: darkPalette()), defaultWidth: 480, defaultHeight: 270)
        let projection = MapProjection.frame(for: value)
        for frame in [0, 29] {
            let raster = try await MapSceneRenderer.sample(value, atlas: .empty, frame: frame)
            for point in projection.points {
                let screen = MapProjection.screen(point, camera: value.camera(at: frame), in: projection)
                #expect(whiteCount(raster, near: CGPoint(x: screen.x, y: screen.y - 28), radius: 50) > 15)
            }
        }
    }

    @Test func shipMovesToArrivalAndDisappearsAtExclusiveEnd() async throws {
        let value = try MapSceneSpec.validated(MapSceneInput(places: [
            .init(name: "origin", latitude: 0, longitude: -1, showPin: false, showLabel: false),
            .init(name: "destination", latitude: 0, longitude: 1, showPin: false, showLabel: false),
        ], connections: [.init(from: "origin", to: "destination", id: "sea", revealFrames: 0)],
            camera: [.init(frame: 0, latitude: 0, longitude: 0)], durationFrames: 30, width: 480, height: 270,
            objects: [.init(id: "ship", kind: .ship, routeId: "sea", startFrame: 8, endFrame: 24, size: 54, entrance: MapSceneEntrance.none)],
            palette: darkPalette()), defaultWidth: 480, defaultHeight: 270)
        let projection = MapProjection.frame(for: value)
        let origin = MapProjection.screen(projection.points[0], camera: value.camera[0], in: projection)
        let destination = MapProjection.screen(projection.points[1], camera: value.camera[0], in: projection)
        let departure = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 8)
        let arrival = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 23)
        let gone = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 24)
        #expect(whiteCount(departure, near: origin, radius: 35) > 100)
        #expect(whiteCount(arrival, near: destination, radius: 35) > 100)
        #expect(whiteCount(gone, near: destination, radius: 35) == 0)
    }

    @Test(arguments: [MapSceneObjectKind.gunfire, .explosion, .heat, .rain])
    func timedEffectsRenderAndAnimate(kind: MapSceneObjectKind) async throws {
        let value = try MapSceneSpec.validated(MapSceneInput(places: [.init(name: "center", latitude: 0, longitude: 0, showPin: false, showLabel: false)],
            durationFrames: 30, width: 480, height: 270,
            objects: [.init(id: "effect", kind: kind, place: "center", startFrame: 3, endFrame: 27, size: 90, color: "#FFA522", entrance: MapSceneEntrance.none)],
            palette: darkPalette()), defaultWidth: 480, defaultHeight: 270)
        let before = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 0)
        let first = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 6)
        let second = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 16)
        #expect(first.pixels != before.pixels)
        #expect(first.pixels != second.pixels)
        #expect(try await MapSceneRenderer.sample(value, atlas: .empty, frame: 27).pixels == before.pixels)
    }

    @Test(arguments: [MapSceneObjectKind.gunfire, .explosion, .heat, .rain])
    func effectsAndLabelsRespectTheirFadeEntrance(kind: MapSceneObjectKind) async throws {
        let value = try MapSceneSpec.validated(MapSceneInput(places: [.init(name: "center", latitude: 0, longitude: 0, showPin: false, showLabel: false)],
            durationFrames: 30, width: 480, height: 270,
            objects: [.init(id: "effect", kind: kind, place: "center", startFrame: 3, endFrame: 27,
                size: 90, color: "#FFA522", label: "HAZARD", entrance: .fade)],
            palette: darkPalette()), defaultWidth: 480, defaultHeight: 270)
        let before = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 0)
        #expect(try await MapSceneRenderer.sample(value, atlas: .empty, frame: 3).pixels == before.pixels)
        #expect(try await MapSceneRenderer.sample(value, atlas: .empty, frame: 12).pixels != before.pixels)
    }

    @Test(arguments: [false, true])
    func arrowsUseFixedRotationOrFollowTheCameraTransformedRoute(moving: Bool) async throws {
        let object = moving
            ? MapSceneObject(id: "arrow", kind: .arrow, routeId: "route", endFrame: 29, size: 90, rotateToPath: true, entrance: MapSceneEntrance.none)
            : MapSceneObject(id: "arrow", kind: .arrow, latitude: 0, longitude: 0, size: 90, rotation: 90, entrance: MapSceneEntrance.none)
        let value = try MapSceneSpec.validated(MapSceneInput(places: [
            .init(name: "origin", latitude: 0, longitude: -1, showPin: false, showLabel: false),
            .init(name: "destination", latitude: 0, longitude: 1, showPin: false, showLabel: false),
        ], connections: [.init(from: "origin", to: "destination", id: "route", revealFrames: 0)],
            camera: [.init(frame: 0, latitude: 0, longitude: 0, rotation: moving ? 90 : 0)],
            durationFrames: 30, width: 480, height: 270, objects: [object], palette: darkPalette()),
            defaultWidth: 480, defaultHeight: 270)
        let raster = try await MapSceneRenderer.sample(value, atlas: .empty, frame: 14)
        #expect(whiteCount(raster, near: CGPoint(x: 240, y: 170), radius: 6) > 20)
        #expect(whiteCount(raster, near: CGPoint(x: 275, y: 135), radius: 6) == 0)
    }

    @Test func encodedVideoHasExactFramesAndRejectsChangedReuseBytes() async throws {
        let spec = try MapSceneSpec.validated(MapSceneInput(places: [.init(name: "Penang")], durationFrames: 12,
            width: 480, height: 270, fps: 24, palette: darkPalette()), defaultWidth: 480, defaultHeight: 270)
        let io = ProjectPackageIO()
        let first = try await MapSceneRenderer.render(spec, atlas: .empty)
        let stage = try #require(first.stage)
        do {
            let video = AVURLAsset(url: stage)
            #expect(abs(try await video.load(.duration).seconds - 0.5) < 0.001)
            let tracks = try await video.loadTracks(withMediaType: .video)
            let track = try #require(tracks.first)
            #expect(abs(try await track.load(.nominalFrameRate) - 24) < 0.1)
            #expect(try await video.loadTracks(withMediaType: .audio).isEmpty)
            let reused = try await MapSceneRenderer.render(spec, atlas: .empty,
                reusable: [first.digest: .init(url: stage, videoDigest: first.videoDigest)])
            #expect(reused.stage == nil)
            try await io.perform { try Data("changed video bytes".utf8).write(to: stage) }
            let repaired = try await MapSceneRenderer.render(spec, atlas: .empty,
                reusable: [first.digest: .init(url: stage, videoDigest: first.videoDigest)])
            let repairedStage = try #require(repaired.stage)
            #expect(repaired.digest == first.digest)
            try await io.remove([repairedStage])
        } catch {
            try await io.remove([stage])
            throw error
        }
        try await io.remove([stage])
    }

    private func darkPalette() -> MapScenePalette {
        var value = MapScenePalette()
        value.relief = false
        value.background = "#073D50"
        value.land = value.background
        value.border = value.background
        value.glow = 0
        value.labelSize = 20
        return value
    }

    @concurrent private func twoTonePNG(swapped: Bool = false) async throws -> Data {
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let index = (y * 64 + x) * 4
                let red = (y < 32) != swapped
                bytes[index] = red ? 0 : 255
                bytes[index + 1] = 0
                bytes[index + 2] = red ? 255 : 0
            }
        }
        return try await MapSceneRaster(width: 64, height: 64, bytesPerRow: 256, pixels: Data(bytes)).png()
    }

    private func pixel(_ raster: MapSceneRaster, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
        let x = min(raster.width - 1, max(0, Int(point.x))), y = min(raster.height - 1, max(0, Int(point.y)))
        let offset = y * raster.bytesPerRow + x * 4
        return (raster.pixels[offset + 2], raster.pixels[offset + 1], raster.pixels[offset])
    }

    private func redCount(_ raster: MapSceneRaster) -> Int {
        var count = 0
        for y in stride(from: 0, to: raster.height, by: 2) {
            for x in stride(from: 0, to: raster.width, by: 2) {
                let color = pixel(raster, at: CGPoint(x: x, y: y))
                if color.r > 180 && color.g < 110 && color.b < 110 { count += 1 }
            }
        }
        return count
    }

    private func whiteCount(_ raster: MapSceneRaster, near point: CGPoint, radius: Int) -> Int {
        var count = 0
        for y in max(0, Int(point.y) - radius)..<min(raster.height, Int(point.y) + radius) {
            for x in max(0, Int(point.x) - radius)..<min(raster.width, Int(point.x) + radius) {
                let color = pixel(raster, at: CGPoint(x: x, y: y))
                if color.r > 200 && color.g > 200 && color.b > 200 { count += 1 }
            }
        }
        return count
    }
}
