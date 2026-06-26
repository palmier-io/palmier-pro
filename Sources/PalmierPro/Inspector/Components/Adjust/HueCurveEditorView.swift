import SwiftUI

struct HueCurveEditorView: View {
    let curves: HueCurves
    var onChange: (HueCurves.Channel, [CurvePoint]) -> Void
    var onCommit: (HueCurves.Channel, [CurvePoint]) -> Void

    @Environment(EditorViewModel.self) private var editor
    @State private var channel: HueCurves.Channel = .hue
    @State private var liveDrag: (points: [CurvePoint], index: Int)?
    @State private var hueHist: [Float] = []
    @State private var histInFlight = false
    @State private var histDirty = false

    private static let spectrum: [Color] = [
        .init(red: 1, green: 0.23, blue: 0.19), .init(red: 0.95, green: 0.85, blue: 0.2),
        .init(red: 0.3, green: 0.85, blue: 0.35), .init(red: 0.2, green: 0.8, blue: 0.85),
        .init(red: 0.25, green: 0.5, blue: 0.95), .init(red: 0.8, green: 0.35, blue: 0.9),
        .init(red: 1, green: 0.23, blue: 0.19),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("", selection: $channel) {
                ForEach(HueCurves.Channel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: AppTheme.Curve.editorHeight)
                ZStack {
                    LinearGradient(colors: Self.spectrum, startPoint: .leading, endPoint: .trailing)
                        .opacity(AppTheme.Opacity.medium)
                    Canvas { ctx, _ in
                        if hueHist.count > 1 {
                            ctx.fill(histogramPath(hueHist, size),
                                     with: .color(.white.opacity(AppTheme.Opacity.muted)))
                            ctx.stroke(histogramLine(hueHist, size),
                                       with: .color(.white.opacity(AppTheme.Opacity.prominent)),
                                       lineWidth: AppTheme.BorderWidth.thin)
                        }
                        var grid = Path()
                        for stop in stride(from: 0.0, through: 1.0, by: 1.0 / 6) {
                            let x = CGFloat(stop) * size.width
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        ctx.stroke(grid, with: .color(AppTheme.Border.subtleColor.opacity(AppTheme.Opacity.medium)),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var mid = Path()
                        mid.move(to: CGPoint(x: 0, y: size.height / 2))
                        mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        ctx.stroke(mid, with: .color(AppTheme.Border.subtleColor),
                                   style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var line = Path()
                        for i in stride(from: 0.0, through: 1.0, by: 0.01) {
                            let p = point(CurvePoint(x: i, y: HueCurves.eval(activePoints, i)), size)
                            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        }
                        ctx.stroke(line, with: .color(AppTheme.Text.primaryColor),
                                   lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .gesture(curveDrag(size))
                    .onTapGesture(count: 2) { location in removeNearest(to: location, size) }

                    ForEach(Array(activePoints.enumerated()), id: \.offset) { _, pt in
                        Circle()
                            .fill(AppTheme.Text.primaryColor)
                            .frame(width: AppTheme.Curve.pointDiameter, height: AppTheme.Curve.pointDiameter)
                            .position(point(pt, size))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            .frame(height: AppTheme.Curve.editorHeight)

            Text("Drag to add or shape a point · double-click to remove")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .onAppear { refreshHistogram() }
        .onChange(of: editor.timelineRenderRevision) { _, _ in refreshHistogram() }
        .onChange(of: editor.activeFrame) { _, _ in refreshHistogram() }
        .onChange(of: editor.isPlaying) { _, playing in if !playing { refreshHistogram() } }
    }

    /// One generator pass in flight at a time; coalesce mid-pass changes into a trailing refresh.
    private func refreshHistogram() {
        guard editor.videoEngine != nil, !editor.isPlaying else { return }
        if histInFlight { histDirty = true; return }
        histInFlight = true
        let frame = editor.activeFrame
        Task { @MainActor in
            if let h = await editor.videoEngine?.hueHistogram(frame: frame) { hueHist = h }
            histInFlight = false
            if histDirty { histDirty = false; refreshHistogram() }
        }
    }

    private func histogramPath(_ bins: [Float], _ size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in bins.enumerated() {
            let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
            path.addLine(to: CGPoint(x: x, y: size.height - CGFloat(v) * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    /// The histogram's top contour only — stroked over the fill.
    private func histogramLine(_ bins: [Float], _ size: CGSize) -> Path {
        var path = Path()
        for (i, v) in bins.enumerated() {
            let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
            let p = CGPoint(x: x, y: size.height - CGFloat(v) * size.height)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private var channelPoints: [CurvePoint] { curves.points(channel) }

    private var displayPoints: [CurvePoint] {
        (channelPoints.isEmpty ? HueCurves.defaultPoints : channelPoints).sorted { $0.x < $1.x }
    }

    /// Points to draw — the live in-flight drag if any, else the committed curve.
    private var activePoints: [CurvePoint] { liveDrag?.points ?? displayPoints }

    private func point(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func value(at location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(x: min(1, max(0, location.x / size.width)),
                   y: min(1, max(0, 1 - location.y / size.height)))
    }

    /// One gesture: grab the nearest point (or drop a new one) at press, then drag it.
    private func curveDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                var d = liveDrag ?? grab(at: v.startLocation, size)
                d.points = moved(d.points, d.index, to: v.location, size)
                liveDrag = d
                emit(d.points, commit: false)
            }
            .onEnded { v in
                if let d = liveDrag { emit(moved(d.points, d.index, to: v.location, size), commit: true) }
                liveDrag = nil
            }
    }

    private func grab(at location: CGPoint, _ size: CGSize) -> (points: [CurvePoint], index: Int) {
        var pts = displayPoints
        if let i = nearestIndex(to: location, in: pts, size) { return (pts, i) }
        let np = value(at: location, size)
        pts.append(np)
        pts.sort { $0.x < $1.x }
        return (pts, pts.firstIndex { $0.x == np.x && $0.y == np.y } ?? 0)
    }

    private func nearestIndex(to location: CGPoint, in pts: [CurvePoint], _ size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let sp = point(p, size)
            let dist = hypot(sp.x - location.x, sp.y - location.y)
            if dist <= AppTheme.Curve.pointHitDiameter / 2, best == nil || dist < best!.1 { best = (i, dist) }
        }
        return best?.0
    }

    private func moved(_ points: [CurvePoint], _ index: Int, to location: CGPoint, _ size: CGSize) -> [CurvePoint] {
        var pts = points
        let v = value(at: location, size)
        pts[index].y = v.y
        if index != 0, index != pts.count - 1 {
            pts[index].x = min(pts[index + 1].x - 0.001, max(pts[index - 1].x + 0.001, v.x))
        }
        return pts
    }

    private func removeNearest(to location: CGPoint, _ size: CGSize) {
        let pts = displayPoints
        guard let i = nearestIndex(to: location, in: pts, size), pts.count > 2, i > 0, i < pts.count - 1 else { return }
        var out = pts; out.remove(at: i)
        emit(out, commit: true)
    }

    private func emit(_ pts: [CurvePoint], commit: Bool) {
        let value = HueCurves.isNeutral(pts) ? [] : pts
        (commit ? onCommit : onChange)(channel, value)
    }
}
