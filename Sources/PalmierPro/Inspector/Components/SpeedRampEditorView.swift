import SwiftUI

struct SpeedRampEditorView: View {
    let ramp: SpeedRamp
    var onChange: (SpeedRamp) -> Void
    var onCommit: (SpeedRamp) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var liveDrag: (points: [SpeedRampPoint], index: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            GeometryReader { geometry in
                let size = CGSize(width: geometry.size.width, height: AppTheme.Curve.editorHeight)
                ZStack {
                    Canvas { context, _ in
                        drawGrid(context: context, size: size)
                        drawReference(context: context, size: size)
                        drawCurve(context: context, size: size)
                    }
                    .contentShape(Rectangle())
                    .gesture(curveDrag(size))
                    .onTapGesture(count: 2) { location in removeNearest(to: location, size) }

                    ForEach(Array(activePoints.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(AppTheme.Accent.primary)
                            .frame(
                                width: AppTheme.Curve.pointDiameter,
                                height: AppTheme.Curve.pointDiameter
                            )
                            .position(canvasPoint(point, size))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: AppTheme.Curve.editorHeight)
            .accessibilityLabel("Speed ramp curve")
            .help("Drag to add or shape a speed point. Double-click an interior point to remove it.")

            HStack {
                Text("Start")
                Spacer()
                Text("0.25x–4x · double-click to remove")
                Spacer()
                Text("End")
            }
            .font(.system(size: AppTheme.FontSize.xxs))
            .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .onDisappear { commitLiveDrag() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { commitLiveDrag() }
        }
    }

    private var sortedPoints: [SpeedRampPoint] {
        ramp.points.sorted { $0.position < $1.position }
    }

    private var activePoints: [SpeedRampPoint] {
        liveDrag?.points ?? sortedPoints
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for stop in stride(from: 0.0, through: 1.0, by: 0.25) {
            let value = CGFloat(stop)
            grid.move(to: CGPoint(x: value * size.width, y: 0))
            grid.addLine(to: CGPoint(x: value * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: value * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: value * size.height))
        }
        context.stroke(
            grid,
            with: .color(AppTheme.Border.subtleColor.opacity(AppTheme.Opacity.medium)),
            lineWidth: AppTheme.BorderWidth.hairline
        )
        context.stroke(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(AppTheme.Border.subtleColor),
            lineWidth: AppTheme.BorderWidth.hairline
        )
    }

    private func drawReference(context: GraphicsContext, size: CGSize) {
        let y = canvasY(for: 1, height: size.height)
        var reference = Path()
        reference.move(to: CGPoint(x: 0, y: y))
        reference.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(
            reference,
            with: .color(AppTheme.Text.mutedColor),
            style: .init(
                lineWidth: AppTheme.BorderWidth.hairline,
                dash: [AppTheme.Spacing.xs, AppTheme.Spacing.xs]
            )
        )
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let activeRamp = SpeedRamp(points: activePoints)
        var path = Path()
        for index in 0...100 {
            let position = Double(index) / 100
            let point = canvasPoint(
                SpeedRampPoint(position: position, speed: activeRamp.speed(at: position)),
                size
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(AppTheme.Accent.primary), lineWidth: AppTheme.BorderWidth.medium)
    }

    private func canvasPoint(_ point: SpeedRampPoint, _ size: CGSize) -> CGPoint {
        CGPoint(
            x: point.position * size.width,
            y: canvasY(for: point.speed, height: size.height)
        )
    }

    private func canvasY(for speed: Double, height: CGFloat) -> CGFloat {
        let range = SpeedRamp.maximumSpeed - SpeedRamp.minimumSpeed
        let normalized = (speed - SpeedRamp.minimumSpeed) / range
        return (1 - normalized) * height
    }

    private func value(at location: CGPoint, _ size: CGSize) -> (position: Double, speed: Double) {
        let position = min(1, max(0, location.x / size.width))
        let normalizedSpeed = min(1, max(0, 1 - location.y / size.height))
        let speed = SpeedRamp.minimumSpeed
            + normalizedSpeed * (SpeedRamp.maximumSpeed - SpeedRamp.minimumSpeed)
        return (position, speed)
    }

    private func curveDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: AppTheme.Spacing.xxs)
            .onChanged { value in
                var drag = liveDrag ?? grab(at: value.startLocation, size)
                drag.points = moved(drag.points, drag.index, to: value.location, size)
                liveDrag = drag
                onChange(SpeedRamp(points: drag.points))
            }
            .onEnded { value in
                if let drag = liveDrag {
                    onCommit(SpeedRamp(points: moved(drag.points, drag.index, to: value.location, size)))
                }
                liveDrag = nil
            }
    }

    private func grab(
        at location: CGPoint,
        _ size: CGSize
    ) -> (points: [SpeedRampPoint], index: Int) {
        var points = sortedPoints
        if let index = nearestIndex(to: location, in: points, size) {
            return (points, index)
        }
        if points.count >= SpeedRamp.maximumAuthoredPointCount {
            let position = value(at: location, size).position
            let index = points.indices.min {
                abs(points[$0].position - position) < abs(points[$1].position - position)
            } ?? 0
            return (points, index)
        }
        let value = value(at: location, size)
        let point = SpeedRampPoint(position: value.position, speed: value.speed)
        points.append(point)
        points.sort { $0.position < $1.position }
        return (points, points.firstIndex(of: point) ?? 0)
    }

    private func nearestIndex(
        to location: CGPoint,
        in points: [SpeedRampPoint],
        _ size: CGSize
    ) -> Int? {
        var nearest: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let rendered = canvasPoint(point, size)
            let distance = hypot(rendered.x - location.x, rendered.y - location.y)
            if distance <= AppTheme.Curve.pointHitDiameter / 2,
               nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }
        return nearest?.index
    }

    private func moved(
        _ points: [SpeedRampPoint],
        _ index: Int,
        to location: CGPoint,
        _ size: CGSize
    ) -> [SpeedRampPoint] {
        var points = points
        for pointIndex in points.indices {
            points[pointIndex].tangent = nil
        }
        let value = value(at: location, size)
        points[index].speed = value.speed
        if index != 0, index != points.count - 1 {
            points[index].position = min(
                points[index + 1].position - 0.001,
                max(points[index - 1].position + 0.001, value.position)
            )
        }
        return points
    }

    private func removeNearest(to location: CGPoint, _ size: CGSize) {
        var points = sortedPoints
        guard let index = nearestIndex(to: location, in: points, size),
              points.count > 2,
              index > 0,
              index < points.count - 1 else { return }
        points.remove(at: index)
        for pointIndex in points.indices {
            points[pointIndex].tangent = nil
        }
        onCommit(SpeedRamp(points: points))
    }

    private func commitLiveDrag() {
        guard let liveDrag else { return }
        onCommit(SpeedRamp(points: liveDrag.points))
        self.liveDrag = nil
    }
}
