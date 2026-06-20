import SwiftUI

private let curveHeight: CGFloat = 150
private let pointDiameter: CGFloat = 9
private let histogramRed = Color(red: 1, green: 0.22, blue: 0.22)
private let histogramGreen = Color(red: 0.25, green: 0.9, blue: 0.35)
private let histogramBlue = Color(red: 0.3, green: 0.5, blue: 1)

struct CurveEditorView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var channel: Channel = .master
    @State private var lastTap: (index: Int, time: Date)?
    @State private var histR: [Float] = []
    @State private var histG: [Float] = []
    @State private var histB: [Float] = []

    enum Channel: String, CaseIterable, Identifiable {
        case master = "M", red = "R", green = "G", blue = "B"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .master: AppTheme.Text.secondaryColor
            case .red: .red
            case .green: .green
            case .blue: .blue
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
                let size = CGSize(width: geo.size.width, height: curveHeight)
                ZStack {
                    Canvas { ctx, _ in
                        // Additive blend so overlapping channels read as combined color.
                        if histR.count > 1 {
                            ctx.blendMode = .plusLighter
                            ctx.fill(histogramPath(histR, size), with: .color(histogramRed.opacity(AppTheme.Opacity.strong)))
                            ctx.fill(histogramPath(histG, size), with: .color(histogramGreen.opacity(AppTheme.Opacity.strong)))
                            ctx.fill(histogramPath(histB, size), with: .color(histogramBlue.opacity(AppTheme.Opacity.strong)))
                            ctx.blendMode = .normal
                        }
                        let border = Path(CGRect(origin: .zero, size: size))
                        ctx.stroke(border, with: .color(AppTheme.Border.subtleColor), lineWidth: AppTheme.BorderWidth.hairline)
                        var diag = Path()
                        diag.move(to: point(CurvePoint(x: 0, y: 0), size))
                        diag.addLine(to: point(CurvePoint(x: 1, y: 1), size))
                        ctx.stroke(diag, with: .color(AppTheme.Border.subtleColor), style: .init(lineWidth: AppTheme.BorderWidth.hairline, dash: [3, 3]))
                        var curve = Path()
                        let pts = sortedPoints
                        for i in stride(from: 0.0, through: 1.0, by: 0.02) {
                            let p = point(CurvePoint(x: i, y: GradeCurve.eval(pts, i)), size)
                            if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                        }
                        ctx.stroke(curve, with: .color(channel.tint), lineWidth: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in addPoint(at: location, size: size) }

                    ForEach(Array(sortedPoints.enumerated()), id: \.offset) { index, pt in
                        Circle()
                            .fill(channel.tint)
                            .frame(width: pointDiameter, height: pointDiameter)
                            .position(point(pt, size))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if abs(value.translation.width) > 2 || abs(value.translation.height) > 2 {
                                            drag(index: index, to: value.location, size: size)
                                        }
                                    }
                                    .onEnded { value in
                                        let moved = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
                                        if !moved { handleTap(index: index) }
                                    }
                            )
                    }
                }
            }
            .frame(height: curveHeight)

            Text("Click to add a point · drag to shape · double-click to remove")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .onAppear { refreshHistogram() }
        .onChange(of: editor.currentFrame) { _, _ in refreshHistogram() }
        .onChange(of: editor.isPlaying) { _, playing in if !playing { refreshHistogram() } }
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

    private func refreshHistogram() {
        guard let engine = editor.videoEngine, !editor.isPlaying else { return }
        Task { @MainActor in
            if let h = await engine.histogramRGB() {
                histR = h.r; histG = h.g; histB = h.b
            }
        }
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

    private var sortedPoints: [CurvePoint] {
        let raw = channelPoints
        return (raw.isEmpty ? GradeCurve.identityPoints : raw).sorted { $0.x < $1.x }
    }

    private var channelPoints: [CurvePoint] {
        let c = editor.timeline.primaries?.curve ?? GradeCurve()
        switch channel {
        case .master: return c.master
        case .red: return c.red
        case .green: return c.green
        case .blue: return c.blue
        }
    }

    private func point(_ p: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }

    private func value(at location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(
            x: min(1, max(0, location.x / size.width)),
            y: min(1, max(0, 1 - location.y / size.height))
        )
    }

    private func drag(index: Int, to location: CGPoint, size: CGSize) {
        var pts = sortedPoints
        let v = value(at: location, size)
        let isEndpoint = index == 0 || index == pts.count - 1
        pts[index].y = v.y
        if !isEndpoint {
            let lo = pts[index - 1].x + 0.001
            let hi = pts[index + 1].x - 0.001
            pts[index].x = min(hi, max(lo, v.x))
        }
        commit(pts)
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        var pts = sortedPoints
        pts.append(value(at: location, size))
        commit(pts.sorted { $0.x < $1.x })
    }

    private func removePoint(at index: Int) {
        var pts = sortedPoints
        guard pts.count > 2, index > 0, index < pts.count - 1 else { return }
        pts.remove(at: index)
        commit(pts)
    }

    private func commit(_ pts: [CurvePoint]) {
        var p = editor.timeline.primaries ?? PrimaryGrade()
        var c = p.curve ?? GradeCurve()
        let value = (pts == GradeCurve.identityPoints) ? [] : pts
        switch channel {
        case .master: c.master = value
        case .red: c.red = value
        case .green: c.green = value
        case .blue: c.blue = value
        }
        p.curve = c.isIdentity ? nil : c
        editor.setColorPrimaries(p)
    }
}
