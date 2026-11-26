import CoreGraphics
import Foundation

struct MapSceneRoutePath: Sendable {
    let points: [CGPoint]
    let distances: [Double]
    let length: Double

    init(_ points: [CGPoint]) {
        self.points = points
        var distances = [0.0]
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
        }
        self.distances = distances
        length = distances.last ?? 0
    }

    func pose(_ progress: Double) -> (point: CGPoint, tangent: CGPoint) {
        let distance = min(1, max(0, progress)) * length
        let index = distances.firstIndex { $0 >= distance && $0 > 0 } ?? (points.count - 1)
        let previous = max(0, index - 1), a = points[previous], b = points[index]
        let span = distances[index] - distances[previous]
        let t = span > 0 ? (distance - distances[previous]) / span : 0
        return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                CGPoint(x: b.x - a.x, y: b.y - a.y))
    }

    func path(through progress: Double = 1) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        let distance = min(1, max(0, progress)) * length
        for index in 1..<points.count {
            if distances[index] <= distance {
                path.addLine(to: points[index])
            } else {
                path.addLine(to: pose(progress).point)
                break
            }
        }
        return path
    }
}

enum MapSceneMotion {
    struct ObjectPose: Sendable {
        var point: CGPoint
        var tangent: CGPoint
        var progress: Double
    }

    static func route(_ connection: MapSceneConnectionRequest, frame: MapProjection.Frame) -> MapSceneRoutePath {
        let coordinates = [connection.from.coordinate] + (connection.input.via ?? []) + [connection.to.coordinate]
        var points = coordinates.map { MapProjection.point($0, in: frame) }
        let wrap = 360 * frame.cosine * frame.baseScale
        for index in 1..<points.count {
            while points[index].x - points[index - 1].x > wrap / 2 { points[index].x -= wrap }
            while points[index].x - points[index - 1].x < -wrap / 2 { points[index].x += wrap }
        }
        let arc = connection.input.arc ?? 0
        if points.count == 2, arc != 0 {
            let a = points[0], b = points[1]
            let control = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * arc,
                                  y: (a.y + b.y) / 2 + (b.x - a.x) * arc)
            points = (0...64).map { index in
                let t = Double(index) / 64, u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                               y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
            }
        }
        return MapSceneRoutePath(points)
    }

    static func object(_ object: MapSceneObjectRequest, at frameIndex: Int, projection: MapProjection.Frame,
                       routes: [String: MapSceneRoutePath]) -> ObjectPose? {
        guard (object.start..<object.end).contains(frameIndex) else { return nil }
        let progress = Double(frameIndex - object.start) / Double(max(1, object.end - object.start - 1))
        if let routeId = object.input.routeId, let route = routes[routeId] {
            let loops = Double(object.input.loopCount ?? 1)
            let loopProgress = progress >= 1 ? 1 : (progress * loops).truncatingRemainder(dividingBy: 1)
            let position = route.pose((object.input.easing ?? .linear).value(loopProgress))
            return .init(point: position.point, tangent: position.tangent, progress: loopProgress)
        }
        let keys = object.keys
        guard let first = keys.first, let last = keys.last else { return nil }
        if keys.count == 1 || frameIndex <= first.frame {
            return .init(point: MapProjection.point(first.coordinate, in: projection), tangent: .zero, progress: progress)
        }
        if frameIndex >= last.frame {
            let a = MapProjection.point(keys[keys.count - 2].coordinate, in: projection)
            var b = MapProjection.point(last.coordinate, in: projection)
            let wrap = 360 * projection.cosine * projection.baseScale
            if b.x - a.x > wrap / 2 { b.x -= wrap }
            if b.x - a.x < -wrap / 2 { b.x += wrap }
            return .init(point: b, tangent: CGPoint(x: b.x - a.x, y: b.y - a.y), progress: progress)
        }
        let index = keys.firstIndex { $0.frame > frameIndex }!
        let before = keys[index - 1], after = keys[index]
        let t = (object.input.easing ?? .linear).value(Double(frameIndex - before.frame) / Double(after.frame - before.frame))
        let a = MapProjection.point(before.coordinate, in: projection)
        var b = MapProjection.point(after.coordinate, in: projection)
        let wrap = 360 * projection.cosine * projection.baseScale
        if b.x - a.x > wrap / 2 { b.x -= wrap }
        if b.x - a.x < -wrap / 2 { b.x += wrap }
        return .init(point: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                     tangent: CGPoint(x: b.x - a.x, y: b.y - a.y), progress: progress)
    }

    static func distanceKilometers(_ a: MapCoordinate, _ b: MapCoordinate) -> Double {
        let latA = a.latitude * .pi / 180, latB = b.latitude * .pi / 180
        let dLat = latB - latA, dLon = MapProjection.longitudeDelta(b.longitude, from: a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(latA) * cos(latB) * pow(sin(dLon / 2), 2)
        return 6_371.0088 * 2 * atan2(sqrt(max(0, h)), sqrt(max(0, 1 - h)))
    }
}
