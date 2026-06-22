import SwiftUI

struct CurveEditorView: View {
    let curve: GradeCurve
    var onChange: (Channel, [CurvePoint]) -> Void
    var onCommit: (Channel, [CurvePoint]) -> Void

    @Environment(EditorViewModel.self) private var editor
    @State private var channel: Channel = .master
    @State private var lastTap: (index: Int, time: Date)?
    @State private var histY: [Float] = []
    @State private var histR: [Float] = []
    @State private var histG: [Float] = []
    @State private var histB: [Float] = []
    @State private var histInFlight = false
    @State private var histDirty = false

    enum Channel: String, CaseIterable, Identifiable {
        case master = "Y", red = "R", green = "G", blue = "B"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .master: AppTheme.Text.secondaryColor
            case .red: AppTheme.Curve.redColor
            case .green: AppTheme.Curve.greenColor
            case .blue: AppTheme.Curve.blueColor
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GeometryReader { geo in
                let size = CGSize(width: geo.size.width, height: AppTheme.Curve.editorHeight)
                ZStack {
                    Canvas { ctx, _ in
                        if histR.count > 1 {
                            // Luma silhouette behind, then the RGB parade additively on top.
                            ctx.fill(histogramPath(histY, size), with: .color(AppTheme.Curve.lumaColor.opacity(AppTheme.Opacity.medium)))
                            ctx.blendMode = .plusLighter
                            ctx.fill(histogramPath(histR, size), with: .color(AppTheme.Curve.redColor.opacity(AppTheme.Opacity.medium)))
                            ctx.fill(histogramPath(histG, size), with: .color(AppTheme.Curve.greenColor.opacity(AppTheme.Opacity.medium)))
                            ctx.fill(histogramPath(histB, size), with: .color(AppTheme.Curve.blueColor.opacity(AppTheme.Opacity.medium)))
                            ctx.blendMode = .normal
                        }
                        // Quarter grid: black · shadow · mid · highlight · white.
                        var grid = Path()
                        for stop in stride(from: 0.0, through: 1.0, by: 0.25) {
                            let s = CGFloat(stop)
                            grid.move(to: CGPoint(x: s * size.width, y: 0))
                            grid.addLine(to: CGPoint(x: s * size.width, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: s * size.height))
                            grid.addLine(to: CGPoint(x: size.width, y: s * size.height))
                        }
                        ctx.stroke(grid, with: .color(AppTheme.Border.subtleColor.opacity(AppTheme.Opacity.medium)),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor),
                                   lineWidth: AppTheme.BorderWidth.hairline)
                        var diag = Path()
                        diag.move(to: point(CurvePoint(x: 0, y: 0), size))
                        diag.addLine(to: point(CurvePoint(x: 1, y: 1), size))
                        ctx.stroke(diag, with: .color(AppTheme.Border.subtleColor),
                                   style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        var line = Path()
                        let pts = sortedPoints
                        for i in stride(from: 0.0, through: 1.0, by: 0.02) {
                            let p = point(CurvePoint(x: i, y: GradeCurve.eval(pts, i)), size)
                            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        }
                        ctx.stroke(line, with: .color(channel.tint), lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in addPoint(at: location, size: size) }

                    ForEach(Array(sortedPoints.enumerated()), id: \.offset) { index, pt in
                        Circle()
                            .fill(channel.tint)
                            .frame(width: AppTheme.Curve.pointDiameter, height: AppTheme.Curve.pointDiameter)
                            .frame(width: AppTheme.Curve.pointHitDiameter, height: AppTheme.Curve.pointHitDiameter)
                            .contentShape(Circle())
                            .position(point(pt, size))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                                            drag(index: index, to: value.location, size: size, commit: false)
                                        }
                                    }
                                    .onEnded { value in
                                        if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                                            drag(index: index, to: value.location, size: size, commit: true)
                                        } else {
                                            handleTap(index: index)
                                        }
                                    }
                            )
                    }
                }
            }
            .frame(height: AppTheme.Curve.editorHeight)

            Text("Click to add a point · drag to shape · double-click to remove")
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
            if let h = await editor.videoEngine?.histogramYRGB(frame: frame) {
                histY = h.y; histR = h.r; histG = h.g; histB = h.b
            }
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

    private func handleTap(index: Int) {
        let now = Date()
        if let last = lastTap, last.index == index, now.timeIntervalSince(last.time) < 0.4 {
            removePoint(at: index)
            lastTap = nil
        } else {
            lastTap = (index, now)
        }
    }

    // MARK: - Points

    private var channelPoints: [CurvePoint] {
        switch channel {
        case .master: curve.master
        case .red: curve.red
        case .green: curve.green
        case .blue: curve.blue
        }
    }

    private var sortedPoints: [CurvePoint] {
        (channelPoints.isEmpty ? GradeCurve.identityPoints : channelPoints).sorted { $0.x < $1.x }
    }

    private func point(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func value(at location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(x: min(1, max(0, location.x / size.width)),
                   y: min(1, max(0, 1 - location.y / size.height)))
    }

    private func drag(index: Int, to location: CGPoint, size: CGSize, commit: Bool) {
        var pts = sortedPoints
        let v = value(at: location, size)
        let isEndpoint = index == 0 || index == pts.count - 1
        pts[index].y = v.y
        if !isEndpoint {
            let lo = pts[index - 1].x + 0.001
            let hi = pts[index + 1].x - 0.001
            pts[index].x = min(hi, max(lo, v.x))
        }
        emit(pts, commit: commit)
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        var pts = sortedPoints
        pts.append(value(at: location, size))
        emit(pts.sorted { $0.x < $1.x }, commit: true)
    }

    private func removePoint(at index: Int) {
        var pts = sortedPoints
        guard pts.count > 2, index > 0, index < pts.count - 1 else { return }
        pts.remove(at: index)
        emit(pts, commit: true)
    }

    private func emit(_ pts: [CurvePoint], commit: Bool) {
        let value = (pts == GradeCurve.identityPoints) ? [] : pts
        (commit ? onCommit : onChange)(channel, value)
    }
}
