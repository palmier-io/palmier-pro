import CoreGraphics
import Foundation
import Testing
@testable import CompositorPro

@Suite("Map scene geography and motion")
struct MapSceneTests {
    @Test func catalogResolvesAliasesAndRejectsUnknown() throws {
        #expect(try MalaysiaPlaceCatalog.resolve("George Town").canonicalName == "Penang")
        #expect(try MalaysiaPlaceCatalog.resolve("kl").canonicalName == "Kuala Lumpur")
        #expect(throws: MapSceneError.unresolvedPlace(name: "Springfield")) { try MalaysiaPlaceCatalog.resolve("Springfield") }
    }

    @Test func bundledAtlasDisambiguatesGeorgiaAndClassifiesTerritories() async throws {
        let atlas = try await MapAtlasStore.shared.snapshot()
        #expect(atlas.regions.count == 471)
        #expect(try atlas.region(named: "country:GEO").name == "Georgia")
        #expect(try atlas.region(named: "subdivision:US-GA").country == "United States of America")
        #expect(throws: MapSceneError.self) { try atlas.region(named: "Georgia") }
        #expect(try atlas.region(named: "subdivision:AU-NT").classification == "Territory")
        #expect(try atlas.region(named: "  MALAYSIA ").polygons.count == 2)
    }

    @Test func cameraKeepsItsGeographicTargetCenteredThroughRotationAndTilt() throws {
        let value = try spec(MapSceneInput(places: [.init(name: "Penang"), .init(name: "Kulim")],
            camera: [.init(frame: 0, place: "Penang", zoom: 0.5, rotation: 20, tilt: 30),
                     .init(frame: 60, place: "Kulim", zoom: 2, rotation: 80, tilt: 50, easing: .linear)],
            durationFrames: 90, width: 960, height: 540))
        let projection = MapProjection.frame(for: value)
        #expect(projection.points[0].x < projection.points[1].x)
        for frame in [0, 30, 60, 89] {
            let camera = value.camera(at: frame)
            let point = MapProjection.screen(MapProjection.point(of: camera.center, in: projection), camera: camera, in: projection)
            #expect(abs(point.x - projection.center.x) < 0.001)
            #expect(abs(point.y - projection.center.y) < 0.001)
        }
        #expect(abs(value.camera(at: 30).zoom - 1) < 0.001)
    }

    @Test func separateCountryComponentsAndRepeatedHighlightEventsRoundTrip() async throws {
        let atlas = try await MapAtlasStore.shared.snapshot()
        let malaysia = try atlas.region(named: "country:MYS")
        let west = try #require(malaysia.polygons.indices.min { MapSceneSpec.center(of: [malaysia.polygons[$0]]).longitude < MapSceneSpec.center(of: [malaysia.polygons[$1]]).longitude })
        let east = try #require(malaysia.polygons.indices.first { $0 != west })
        let input = MapSceneInput(places: [.init(name: "country:MYS", showPin: false, showLabel: false)],
            durationFrames: 120, regions: [
                .init(name: "Malaysia", id: "peninsula", componentIndices: [west], color: "#FF5544", endFrame: 60),
                .init(name: "Malaysia", id: "borneo", componentIndices: [east], color: "#44AAFF", revealFrame: 60),
            ], objects: [.init(id: "port", kind: .factory, place: "Malaysia")],
            texts: [.init(id: "name", text: "MALAYSIA", place: "Malaysia")])
        let value = try spec(input, atlas: atlas)
        #expect(value.regions[0].center.longitude < value.regions[1].center.longitude)
        #expect(value.regions.map(\.id) == ["peninsula", "borneo"])
        #expect(value.authoredInput.regions?.map(\.name) == ["country:MYS", "country:MYS"])
        let restored = try spec(value.authoredInput, atlas: atlas)
        #expect(try restored.digest == value.digest)
        #expect(value.authoredInput.objects?.first?.latitude != nil)
        #expect(value.authoredInput.texts?.first?.place == "country:MYS")
    }

    @Test func curvedRouteObjectHasExactStartArrivalAndExclusiveEnd() throws {
        let value = try spec(MapSceneInput(places: [
            .init(name: "origin", latitude: 0, longitude: -1), .init(name: "destination", latitude: 0, longitude: 1),
        ], connections: [.init(from: "origin", to: "destination", id: "cargo", revealFrames: 6, arc: 0.4)],
            durationFrames: 60, objects: [.init(id: "ship", kind: .ship, routeId: "cargo", startFrame: 10, endFrame: 40)]))
        let projection = MapProjection.frame(for: value)
        let route = MapSceneMotion.route(value.connections[0], frame: projection)
        let object = value.objects[0]
        let routes = ["cargo": route]
        #expect(MapSceneMotion.object(object, at: 9, projection: projection, routes: routes) == nil)
        #expect(MapSceneMotion.object(object, at: 10, projection: projection, routes: routes)?.point == projection.points[0])
        #expect(MapSceneMotion.object(object, at: 39, projection: projection, routes: routes)?.point == projection.points[1])
        #expect(MapSceneMotion.object(object, at: 40, projection: projection, routes: routes) == nil)
        let midpoint = try #require(MapSceneMotion.object(object, at: 25, projection: projection, routes: routes))
        #expect(midpoint.point.y > projection.points[0].y + 10)
        #expect(route.length > hypot(projection.points[1].x - projection.points[0].x, projection.points[1].y - projection.points[0].y))
    }

    @Test func timedWaypointsCrossDatelineAlongTheShortPathAndKeepArrivalDirection() throws {
        let value = try spec(MapSceneInput(places: [.init(name: "pacific", latitude: 0, longitude: 180)],
            durationFrames: 60, objects: [.init(id: "plane", kind: .airplane,
                waypoints: [.init(frame: 0, latitude: 0, longitude: 170), .init(frame: 59, latitude: 0, longitude: -170)],
                endFrame: 60, rotateToPath: true)]))
        let projection = MapProjection.frame(for: value)
        let halfway = try #require(MapSceneMotion.object(value.objects[0], at: 30, projection: projection, routes: [:]))
        let arrival = try #require(MapSceneMotion.object(value.objects[0], at: 59, projection: projection, routes: [:]))
        #expect(halfway.tangent.x > 0)
        #expect(arrival.tangent.x > 0)
        #expect(abs(halfway.point.x) < projection.baseScale)
        #expect(abs(MapSceneMotion.distanceKilometers(.init(latitude: 0, longitude: 170), .init(latitude: 0, longitude: -170)) - 2223.9) < 1)
    }

    @Test func visualChangesArePartOfTheDigest() throws {
        var input = MapSceneInput(places: [.init(name: "Penang")], durationFrames: 30,
            texts: [.init(id: "title", text: "TRADE", fontSize: 70, color: "#FFFFFF")])
        let original = try spec(input).digest
        input.texts?[0].color = "#FF5533"
        #expect(try spec(input).digest != original)
        input.texts?[0].color = "#FFFFFF"
        input.objects = [.init(id: "cargo", kind: .package, place: "Penang", size: 70)]
        #expect(try spec(input).digest != original)
    }

    @Test func validationRejectsDuplicatesUnknownAndUnevidencedLinks() throws {
        #expect(throws: MapSceneError.duplicatePlace(name: "George Town")) {
            try spec(.init(places: [.init(name: "Penang"), .init(name: "George Town")]))
        }
        #expect(throws: MapSceneError.self) { try spec(.init(places: [.init(name: "Nowhere")])) }
        #expect(throws: MapSceneError.connectionNeedsClaims(from: "Penang", to: "Kulim")) {
            try spec(.init(places: [.init(name: "Penang"), .init(name: "Kulim")], connections: [.init(from: "Penang", to: "Kulim", kind: "sourced")]))
        }
    }

    @Test func ambiguousSceneAliasesCannotSilentlySelectTheFirstGeorgia() async throws {
        let atlas = try await MapAtlasStore.shared.snapshot()
        #expect(throws: MapSceneError.ambiguousPlace(name: "Georgia")) {
            try spec(.init(places: [.init(name: "country:GEO"), .init(name: "subdivision:US-GA")],
                objects: [.init(id: "ambiguous", kind: .pin, place: "Georgia")]), atlas: atlas)
        }
    }

    @Test(arguments: [0, 121, Int.max]) func invalidFPSRefusesBeforeArithmetic(fps: Int) throws {
        #expect(throws: MapSceneError.self) { try spec(.init(places: [.init(name: "Penang")], fps: fps)) }
    }

    @Test func invalidGeometryTimingAndIgnoredCombinationsAreRefused() throws {
        let places: [MapScenePlace] = [.init(name: "Penang"), .init(name: "Kulim")]
        let invalid: [MapSceneInput] = [
            .init(places: places, camera: [.init(frame: 999, place: "Penang")], durationFrames: 60),
            .init(places: places, camera: [.init(frame: 0, place: "Penang", zoom: 129)]),
            .init(places: [.init(name: "bad", latitude: .nan, longitude: 0)]),
            .init(places: places, regions: [.init(name: "empty", polygon: [[0, 0], [1, 0], [2, 0], [0, 0]])]),
            .init(places: places, connections: [.init(from: "Penang", to: "Kulim", via: [.init(latitude: 5, longitude: 100)], arc: 0.2)]),
        ]
        for input in invalid { #expect(throws: MapSceneError.self) { try spec(input) } }
        #expect(throws: MapSceneError.self) { try spec(.init(places: places, objects: [.init(id: "bad", kind: .ship, routeId: "missing")])) }
        #expect(throws: MapSceneError.self) {
            try spec(.init(places: places, objects: [.init(id: "bad", kind: .package,
                waypoints: [.init(frame: 0, place: "Penang"), .init(frame: 20, place: "Kulim")], loopCount: 2)]))
        }
        #expect(throws: MapSceneError.self) {
            try spec(.init(places: places, connections: [.init(from: "Penang", to: "Kulim", endFrame: 5, revealFrames: 10)]))
        }
    }

    private func spec(_ input: MapSceneInput, atlas: MapAtlas = .empty) throws -> MapSceneSpec {
        try MapSceneSpec.validated(input, defaultWidth: 480, defaultHeight: 270, atlas: atlas)
    }
}
