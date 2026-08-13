import AppKit
import SwiftUI

private enum MarkerHalf { case start, end }

private func markerPath(in rect: CGRect, half: MarkerHalf? = nil) -> CGPath {
    let mid = rect.midX
    let tip = CGPoint(x: mid, y: rect.maxY)
    let points: [CGPoint] = switch half {
    case .start: [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: mid, y: rect.minY),
        tip, CGPoint(x: rect.minX, y: rect.maxY - rect.width / 2),
    ]
    case .end: [
        CGPoint(x: mid, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY - rect.width / 2), tip,
    ]
    case nil: [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY - rect.width / 2), tip,
        CGPoint(x: rect.minX, y: rect.maxY - rect.width / 2),
    ]
    }
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

struct TimelineMarkerShape: Shape {
    func path(in rect: CGRect) -> Path { Path(markerPath(in: rect)) }
}

enum TimelineMarkerRenderer {
    typealias ClipRect = (String) -> NSRect?
    private typealias Lane = (minY: CGFloat, height: CGFloat)

    static func draw(
        _ markers: [TimelineMarker], selectedIds: Set<String>, geometry: TimelineGeometry,
        rulerMinY: CGFloat, clipRect: ClipRect, context: CGContext
    ) {
        for marker in markers {
            guard let lane = lane(for: marker, geometry: geometry, rulerMinY: rulerMinY, clipRect: clipRect) else { continue }
            draw(marker, selected: selectedIds.contains(marker.id), geometry: geometry, lane: lane, context: context)
        }
    }

    static func marker(
        at point: NSPoint, markers: [TimelineMarker], geometry: TimelineGeometry,
        rulerMinY: CGFloat, clipRect: ClipRect
    ) -> TimelineMarker? {
        markers.reversed().first {
            guard let lane = lane(for: $0, geometry: geometry, rulerMinY: rulerMinY, clipRect: clipRect) else { return false }
            return endpointRects(for: $0, geometry: geometry, lane: lane).contains { $0.contains(point) }
        }
    }

    static func markerIds(
        intersecting selection: NSRect, markers: [TimelineMarker], geometry: TimelineGeometry,
        rulerMinY: CGFloat, clipRect: ClipRect
    ) -> Set<String> {
        Set(markers.compactMap {
            guard let lane = lane(for: $0, geometry: geometry, rulerMinY: rulerMinY, clipRect: clipRect) else { return nil }
            return endpointRects(for: $0, geometry: geometry, lane: lane)
                .contains { $0.intersects(selection) } ? $0.id : nil
        })
    }

    static func anchorRect(
        for marker: TimelineMarker, geometry: TimelineGeometry, rulerMinY: CGFloat,
        clipRect: ClipRect
    ) -> NSRect? {
        guard let lane = lane(
            for: marker, geometry: geometry, rulerMinY: rulerMinY, clipRect: clipRect
        ) else { return nil }
        return flagRect(for: marker, geometry: geometry, lane: lane)
    }

    private static func lane(
        for marker: TimelineMarker, geometry: TimelineGeometry,
        rulerMinY: CGFloat, clipRect: ClipRect
    ) -> Lane? {
        guard let clipId = marker.clipId else { return (rulerMinY, geometry.rulerHeight) }
        guard let rect = clipRect(clipId) else { return nil }
        return (rect.maxY - AppTheme.TimelineMarker.flagHeight, AppTheme.TimelineMarker.flagHeight)
    }

    private static func draw(
        _ marker: TimelineMarker, selected: Bool, geometry: TimelineGeometry,
        lane: Lane, context: CGContext
    ) {
        let startX = geometry.xForFrame(marker.startFrame)
        let flag = flagRect(for: marker, geometry: geometry, lane: lane)
        let color = marker.color.nsColor
        let paths: [CGPath]
        if marker.isRange {
            let endX = geometry.xForFrame(marker.endFrame)
            context.setFillColor(color.withAlphaComponent(
                color.alphaComponent * AppTheme.Opacity.strong
            ).cgColor)
            context.fill(CGRect(
                x: startX, y: lane.minY + lane.height - AppTheme.TimelineMarker.rangeBarHeight,
                width: max(0, endX - startX), height: AppTheme.TimelineMarker.rangeBarHeight
            ))
            paths = [
                markerPath(in: flag, half: .start),
                markerPath(in: flag.offsetBy(dx: endX - startX, dy: 0), half: .end),
            ]
        } else {
            paths = [markerPath(in: flag)]
        }
        for path in paths {
            context.setFillColor(color.cgColor)
            context.addPath(path); context.fillPath()
            context.setStrokeColor(
                (selected ? AppTheme.Border.timelineMarkerSelected : AppTheme.Border.timelineMarker).cgColor
            )
            context.setLineWidth(selected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin)
            context.addPath(path); context.strokePath()
        }
    }

    private static func flagRect(
        for marker: TimelineMarker, geometry: TimelineGeometry, lane: Lane
    ) -> NSRect {
        NSRect(
            x: geometry.xForFrame(marker.startFrame) - AppTheme.TimelineMarker.flagWidth / 2,
            y: lane.minY + lane.height - AppTheme.TimelineMarker.flagHeight,
            width: AppTheme.TimelineMarker.flagWidth,
            height: AppTheme.TimelineMarker.flagHeight
        )
    }

    private static func endpointRects(
        for marker: TimelineMarker, geometry: TimelineGeometry, lane: Lane
    ) -> [NSRect] {
        let flag = flagRect(for: marker, geometry: geometry, lane: lane)
        var rects = marker.isRange
            ? [
                NSRect(x: flag.minX, y: flag.minY, width: flag.width / 2, height: flag.height),
                NSRect(x: geometry.xForFrame(marker.endFrame), y: flag.minY,
                       width: flag.width / 2, height: flag.height),
            ]
            : [flag]
        return rects.map {
            $0.insetBy(dx: -AppTheme.TimelineMarker.hitSlop, dy: -AppTheme.TimelineMarker.hitSlop)
        }
    }
}
