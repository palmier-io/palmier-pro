import CoreGraphics
import CoreText
import Foundation
import ImageIO

struct MapSceneCanvas {
    private struct Region {
        let request: MapSceneRegionRequest
        let path: CGPath
        let color: CGColor
        let label: MapSceneTextLayout
    }

    private let spec: MapSceneSpec
    private let projection: MapProjection.Frame
    private let worldWidth: Double
    private let land: CGPath
    private let regions: [Region]
    private let routes: [String: MapSceneRoutePath]
    private let images: [String: CGImage]
    private let placeLabels: [MapSceneTextLayout]
    private let routeLabels: [String: MapSceneTextLayout]
    private let objectLabels: [String: MapSceneTextLayout]
    private let textLabels: [String: [MapSceneTextLayout]]
    private let textCoordinates: [String: MapCoordinate]
    private let colors: [String: CGColor]
    private let symbols = MapSceneSymbols()

    init(spec: MapSceneSpec, atlas: MapAtlas, resources: MapSceneRenderResources) throws {
        self.spec = spec
        let projection = MapProjection.frame(for: spec)
        self.projection = projection
        worldWidth = 360 * projection.cosine * projection.baseScale
        land = Self.path(atlas.regions.filter { $0.level == "country" }.flatMap(\.polygons), projection: projection)
        regions = try spec.regions.map {
            Region(request: $0, path: Self.path($0.polygons, projection: projection),
                color: try MapSceneColor($0.input.color ?? spec.palette.pin).cgColor,
                label: MapSceneTextLayout($0.label, size: spec.palette.labelSize, color: try MapSceneColor(spec.palette.text).cgColor,
                    width: Double(spec.width) * 0.7))
        }
        routes = Dictionary(uniqueKeysWithValues: spec.connections.map { ($0.id, MapSceneMotion.route($0, frame: projection)) })
        var decoded: [String: CGImage] = [:]
        var decodedBytes = 0
        for (key, bytes) in resources.images.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: key == MapSceneRenderResources.reliefKey ? 4096 : 2048,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else {
                throw MapSceneError.invalidSpec("Map image '\(key)' could not be decoded.")
            }
            decodedBytes += image.bytesPerRow * image.height
            guard decodedBytes <= 128 * 1_024 * 1_024 else {
                throw MapSceneError.invalidSpec("Decoded map images exceed the 128 MiB scene limit.")
            }
            decoded[key] = image
        }
        images = decoded
        let textColor = try MapSceneColor(spec.palette.text).cgColor
        placeLabels = spec.places.map { MapSceneTextLayout($0.label, size: spec.palette.labelSize,
            color: textColor, width: Double(spec.width) * 0.7) }
        var routeLabels: [String: MapSceneTextLayout] = [:]
        for route in spec.connections {
            var value = route.input.label ?? ""
            if route.input.distanceLabel == true {
                let distance = MapSceneMotion.distanceKilometers(route.from.coordinate, route.to.coordinate)
                value += (value.isEmpty ? "" : "\n") + "≈ \(Int(distance.rounded())) km"
            }
            if !value.isEmpty {
                routeLabels[route.id] = MapSceneTextLayout(value, size: spec.palette.labelSize, color: textColor,
                    width: Double(spec.width) * 0.7)
            }
        }
        self.routeLabels = routeLabels
        objectLabels = Dictionary(uniqueKeysWithValues: spec.objects.compactMap { object in
            object.input.label.map { (object.input.id, MapSceneTextLayout($0, size: spec.palette.labelSize,
                color: textColor, width: Double(spec.width) * 0.7)) }
        })
        var textLabels: [String: [MapSceneTextLayout]] = [:]
        var textCoordinates: [String: MapCoordinate] = [:]
        for text in spec.texts {
            let color = try MapSceneColor(text.color ?? spec.palette.text).cgColor
            let strings = text.entrance == .typewriter ? (0...text.text.count).map { String(text.text.prefix($0)) } : [text.text]
            textLabels[text.id] = strings.map { MapSceneTextLayout($0, size: text.fontSize ?? 48,
                color: color, width: Double(spec.width) * 0.84) }
            if let place = text.place {
                textCoordinates[text.id] = try MapSceneSpec.location(place: place, latitude: nil, longitude: nil,
                    atlas: atlas, scenePlaces: spec.places)
            }
        }
        self.textLabels = textLabels
        self.textCoordinates = textCoordinates
        let colorValues = [spec.palette.background, spec.palette.land, spec.palette.border, spec.palette.pin,
            spec.palette.route, spec.palette.text] + spec.connections.map { $0.input.color ?? spec.palette.route }
            + spec.objects.map { $0.input.color ?? spec.palette.text }
        colors = try Dictionary(uniqueKeysWithValues: Set(colorValues).map { ($0, try MapSceneColor($0).cgColor) })
    }

    func draw(in context: CGContext, frame: Int) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: Double(spec.height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(colors[spec.palette.background]!)
        context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
        let camera = spec.camera(at: frame)
        let transform = MapProjection.transform(camera, in: projection)
        context.saveGState()
        context.concatenate(transform)
        for offset in [-worldWidth, 0, worldWidth] {
            context.saveGState()
            context.translateBy(x: offset, y: 0)
            drawGeography(context, frame: frame, zoom: camera.zoom)
            context.restoreGState()
        }
        context.restoreGState()

        for (index, place) in spec.places.enumerated() where frame >= place.revealFrame {
            let point = visiblePoint(projection.points[index], transform: transform)
            let alpha = reveal(frame: frame, start: place.revealFrame)
            context.saveGState()
            context.setAlpha(alpha)
            if place.showPin {
                context.setFillColor(colors[spec.palette.pin]!)
                context.setShadow(offset: .zero, blur: 5, color: CGColor(gray: 0, alpha: 0.8))
                context.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            }
            if place.showLabel { placeLabels[index].draw(context, at: CGPoint(x: point.x, y: point.y - 28)) }
            context.restoreGState()
        }
        for region in regions where active(frame, start: region.request.input.revealFrame, end: region.request.input.endFrame) {
            guard region.request.input.showLabel != false else { continue }
            context.saveGState()
            context.setAlpha(reveal(frame: frame, start: region.request.input.revealFrame ?? 0))
            region.label.draw(context, at: visiblePoint(MapProjection.point(region.request.center, in: projection), transform: transform))
            context.restoreGState()
        }
        for connection in spec.connections where active(frame, start: connection.revealFrame, end: connection.input.endFrame) {
            guard let route = routes[connection.id], let label = routeLabels[connection.id] else { continue }
            let pose = visiblePoint(route.pose(0.5).point, transform: transform)
            label.draw(context, at: CGPoint(x: pose.x, y: pose.y - 20))
        }
        for object in spec.objects {
            guard let pose = MapSceneMotion.object(object, at: frame, projection: projection, routes: routes) else { continue }
            var point = visiblePoint(pose.point, transform: transform)
            let entry = entrance(object.input.entrance ?? .pop, frame: frame, start: object.start)
            point.y += entry.slide
            context.saveGState()
            context.setAlpha(entry.alpha)
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: (object.input.rotation ?? 0) * .pi / 180)
            if object.input.rotateToPath == true, pose.tangent != .zero {
                let dx = transform.a * pose.tangent.x + transform.c * pose.tangent.y
                let dy = transform.b * pose.tangent.x + transform.d * pose.tangent.y
                context.rotate(by: atan2(dy, dx))
            }
            let size = (object.input.size ?? 54) * entry.scale
            context.scaleBy(x: size, y: size)
            context.setFillColor(colors[object.input.color ?? spec.palette.text]!)
            context.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
            context.setLineWidth(0.035)
            context.setLineJoin(.round)
            context.setShadow(offset: CGSize(width: 0.02, height: 0.03), blur: 0.06, color: CGColor(gray: 0, alpha: 0.65))
            if let reference = object.input.imageMediaRef, let image = images[reference] {
                Self.drawImage(image, in: CGRect(x: -0.5, y: -0.5, width: 1, height: 1), context: context, fit: true)
            } else {
                symbols.draw(object.input.kind, context: context, color: colors[object.input.color ?? spec.palette.text]!,
                    elapsed: Double(frame - object.start) / Double(spec.fps), progress: pose.progress, opacity: entry.alpha)
            }
            context.restoreGState()
            context.saveGState()
            context.setAlpha(entry.alpha)
            objectLabels[object.input.id]?.draw(context, at: CGPoint(x: point.x, y: point.y + size * 0.6 + 18))
            context.restoreGState()
        }
        for text in spec.texts where active(frame, start: text.startFrame, end: text.endFrame) {
            guard let labels = textLabels[text.id] else { continue }
            let start = text.startFrame ?? 0
            let entry = entrance(text.entrance ?? .pop, frame: frame, start: start)
            var point = textCoordinates[text.id].map { visiblePoint(MapProjection.point($0, in: projection), transform: transform) }
                ?? CGPoint(x: (text.x ?? 0.5) * Double(spec.width), y: (text.y ?? 0.15) * Double(spec.height))
            point.y += entry.slide
            let index = text.entrance == .typewriter ? min(labels.count - 1, max(0, Int(Double(frame - start) / Double(spec.fps) * 30))) : 0
            context.saveGState()
            context.setAlpha(entry.alpha)
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: (text.rotation ?? 0) * .pi / 180)
            context.scaleBy(x: entry.scale, y: entry.scale)
            labels[index].draw(context, at: .zero)
            context.restoreGState()
        }
    }

    private func drawGeography(_ context: CGContext, frame: Int, zoom: Double) {
        if let background = spec.backgroundImage, let image = images[background.mediaRef] {
            let origin = MapProjection.point(.init(latitude: background.north, longitude: background.west), in: projection)
            Self.drawImage(image, in: CGRect(x: origin.x, y: origin.y,
                width: (background.east - background.west) * projection.cosine * projection.baseScale,
                height: (background.north - background.south) * projection.baseScale), context: context)
        } else if let image = images[MapSceneRenderResources.reliefKey] {
            let origin = MapProjection.point(.init(latitude: 90, longitude: -180), in: projection)
            Self.drawImage(image, in: CGRect(x: origin.x, y: origin.y, width: worldWidth, height: 180 * projection.baseScale), context: context)
        } else {
            context.setFillColor(colors[spec.palette.land]!)
            context.addPath(land)
            context.fillPath(using: .evenOdd)
        }
        context.setStrokeColor(colors[spec.palette.border]!.copy(alpha: 0.45)!)
        context.setLineWidth(0.7 / zoom)
        context.addPath(land)
        context.strokePath()
        for region in regions where active(frame, start: region.request.input.revealFrame, end: region.request.input.endFrame) {
            let raw = region.request.input
            let pulse = raw.pulse == true ? 0.8 + 0.2 * sin(Double(frame) / Double(spec.fps) * .pi * 2) : 1
            context.saveGState()
            context.setAlpha((raw.opacity ?? 0.75) * pulse * reveal(frame: frame, start: raw.revealFrame ?? 0))
            context.setFillColor(region.color)
            context.setShadow(offset: .zero, blur: spec.palette.glow / zoom, color: region.color)
            context.addPath(region.path)
            context.fillPath(using: .evenOdd)
            context.setShadow(offset: .zero, blur: 0)
            if let reference = raw.imageMediaRef, let image = images[reference] {
                context.saveGState()
                context.addPath(region.path)
                context.clip(using: .evenOdd)
                Self.drawImage(image, in: region.path.boundingBoxOfPath, context: context)
                context.restoreGState()
            }
            context.setStrokeColor(region.color)
            context.setLineWidth(2.5 / zoom)
            context.addPath(region.path)
            context.strokePath()
            context.restoreGState()
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for connection in spec.connections where active(frame, start: connection.revealFrame, end: connection.input.endFrame) {
            guard let route = routes[connection.id] else { continue }
            let revealFrames = connection.input.revealFrames ?? 18
            let progress = revealFrames == 0 ? 1 : min(1, Double(frame - connection.revealFrame) / Double(revealFrames))
            context.saveGState()
            context.setStrokeColor(colors[connection.input.color ?? spec.palette.route]!)
            context.setLineWidth((connection.input.width ?? 4) / zoom)
            context.setShadow(offset: .zero, blur: spec.palette.glow / zoom, color: colors[connection.input.color ?? spec.palette.route])
            context.addPath(route.path(through: progress))
            context.strokePath()
            context.restoreGState()
        }
    }

    private func active(_ frame: Int, start: Int?, end: Int?) -> Bool {
        ((start ?? 0)..<(end ?? spec.durationFrames)).contains(frame)
    }

    private func reveal(frame: Int, start: Int) -> Double {
        start == 0 ? 1 : MapSceneEasing.easeOut.value(Double(frame - start) / (Double(spec.fps) * 0.3))
    }

    private func entrance(_ kind: MapSceneEntrance, frame: Int, start: Int) -> (alpha: Double, scale: Double, slide: Double) {
        let t = MapSceneEasing.easeOut.value(Double(frame - start) / (Double(spec.fps) * 0.25))
        switch kind {
        case .none, .typewriter: return (1, 1, 0)
        case .fade: return (t, 1, 0)
        case .pop: return (t, 0.65 + 0.35 * t, 0)
        case .slide: return (t, 1, 30 * (1 - t))
        }
    }

    private func visiblePoint(_ plane: CGPoint, transform: CGAffineTransform) -> CGPoint {
        [-worldWidth, 0, worldWidth].map { CGPoint(x: plane.x + $0, y: plane.y).applying(transform) }
            .min { hypot($0.x - projection.center.x, $0.y - projection.center.y) < hypot($1.x - projection.center.x, $1.y - projection.center.y) }!
    }

    static func path(_ polygons: [[[MapCoordinate]]], projection: MapProjection.Frame) -> CGPath {
        let path = CGMutablePath()
        let wrap = 360 * projection.cosine * projection.baseScale
        for polygon in polygons {
            var outerX: Double?
            for ring in polygon {
                guard let first = ring.first else { continue }
                var previous = MapProjection.point(first, in: projection)
                if let outerX {
                    while previous.x - outerX > wrap / 2 { previous.x -= wrap }
                    while previous.x - outerX < -wrap / 2 { previous.x += wrap }
                } else { outerX = previous.x }
                path.move(to: previous)
                for coordinate in ring.dropFirst() {
                    var point = MapProjection.point(coordinate, in: projection)
                    while point.x - previous.x > wrap / 2 { point.x -= wrap }
                    while point.x - previous.x < -wrap / 2 { point.x += wrap }
                    path.addLine(to: point)
                    previous = point
                }
                path.closeSubpath()
            }
        }
        return path
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext, fit: Bool = false) {
        var target = rect
        if fit {
            let scale = min(rect.width / Double(image.width), rect.height / Double(image.height))
            let width = Double(image.width) * scale, height = Double(image.height) * scale
            target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.restoreGState()
    }
}

private struct MapSceneTextLayout {
    let lines: [CTLine]
    let widths: [Double]
    let size: Double

    init(_ text: String, size: Double, color: CGColor, width: Double) {
        self.size = size
        let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: 0.05, alpha: 1),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -3,
        ])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [CTLine] = [], widths: [Double] = []
        var offset = 0
        while offset < string.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, width))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            lines.append(line)
            widths.append(CTLineGetTypographicBounds(line, nil, nil, nil))
            offset += count
        }
        self.lines = lines
        self.widths = widths
    }

    func draw(_ context: CGContext, at point: CGPoint) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 0.8))
        for index in lines.indices {
            context.textPosition = CGPoint(x: -widths[index] / 2,
                y: (Double(lines.count - 1) / 2 - Double(index)) * size * 1.12 - size * 0.32)
            CTLineDraw(lines[index], context)
        }
    }
}
