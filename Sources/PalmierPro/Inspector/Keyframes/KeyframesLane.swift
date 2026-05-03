import AppKit
import SwiftUI

enum KeyframesMetrics {
    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 14
    static let headerHeight: CGFloat = rulerHeight + stripHeight
    static let rowHeight: CGFloat = 22
    static let stampButtonWidth: CGFloat = 22
    static let diamondSize: CGFloat = 8

    /// Map a timeline frame into the lane's local x. Inverse of `frameAt(...)`.
    static func xForFrame(_ f: Int, clipStart: Int, span: Int, width: CGFloat) -> CGFloat {
        let t = Double(f - clipStart) / Double(max(1, span))
        return CGFloat(max(0, min(1, t))) * width
    }

    /// Map a local x back to a timeline frame, clamped to the clip's range.
    static func frameAt(x: CGFloat, clipStart: Int, span: Int, width: CGFloat) -> Int {
        guard width > 0 else { return clipStart }
        let t = max(0, min(1, x / width))
        return clipStart + Int((t * Double(span)).rounded())
    }
}

/// Inspector ruler + colored clip strip block
struct ClipRulerBlock: View {
    let clip: Clip
    let tint: Color
    let onSeek: (Int) -> Void
    @Environment(EditorViewModel.self) private var editor

    private var span: Int { max(1, clip.endFrame - clip.startFrame) }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                RulerView(clipStart: clip.startFrame, span: span, fps: editor.timeline.fps)
                    .frame(height: KeyframesMetrics.rulerHeight)
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.35))
                    .overlay(alignment: .leading) {
                        Text(editor.clipDisplayLabel(for: clip))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 5)
                            .lineLimit(1)
                    }
                    .frame(height: KeyframesMetrics.stripHeight)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in seek(at: v.location.x, width: proxy.size.width) }
                    .onEnded { v in seek(at: v.location.x, width: proxy.size.width) }
            )
        }
        .frame(height: KeyframesMetrics.rulerHeight + KeyframesMetrics.stripHeight)
    }

    private func seek(at x: CGFloat, width: CGFloat) {
        onSeek(KeyframesMetrics.frameAt(x: x, clipStart: clip.startFrame, span: span, width: width))
    }
}

/// Per-property keyframe track
struct KeyframesLaneRow: View {
    let clip: Clip
    let property: AnimatableProperty
    let frames: [Int]
    let tint: Color
    @Binding var snapX: CGFloat?

    @Environment(EditorViewModel.self) private var editor
    @State private var drag: KFDrag?
    @State private var snapState = SnapEngine.SnapState()

    private struct KFDrag {
        let originalFrame: Int
        var currentFrame: Int
    }

    private static let hitTolerance: CGFloat = 7
    private static let snapThresholdPixels: Double = 4
    private var span: Int { max(1, clip.endFrame - clip.startFrame) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.04))
                Canvas { ctx, size in
                    let half = KeyframesMetrics.diamondSize / 2
                    let y = size.height / 2
                    for f in displayedFrames() {
                        let x = KeyframesMetrics.xForFrame(f, clipStart: clip.startFrame, span: span, width: size.width)
                        var d = Path()
                        d.move(to: CGPoint(x: x, y: y - half))
                        d.addLine(to: CGPoint(x: x + half, y: y))
                        d.addLine(to: CGPoint(x: x, y: y + half))
                        d.addLine(to: CGPoint(x: x - half, y: y))
                        d.closeSubpath()
                        ctx.fill(d, with: .color(tint))
                        ctx.stroke(d, with: .color(.black.opacity(0.4)), lineWidth: 0.5)
                    }
                }

                // Per-kf invisible hit areas for right-click context menus.
                ForEach(frames, id: \.self) { kf in
                    let x = KeyframesMetrics.xForFrame(kf, clipStart: clip.startFrame, span: span, width: proxy.size.width)
                    Color.clear
                        .frame(width: Self.hitTolerance * 2, height: KeyframesMetrics.rowHeight)
                        .position(x: x, y: KeyframesMetrics.rowHeight / 2)
                        .contextMenu { contextMenu(for: kf) }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: proxy.size.width))
        }
    }

    private func displayedFrames() -> [Int] {
        guard let drag else { return frames }
        return frames.map { $0 == drag.originalFrame ? drag.currentFrame : $0 }
    }

    // MARK: - Gestures

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    if let hit = nearestKf(at: value.startLocation.x, width: width) {
                        drag = KFDrag(originalFrame: hit, currentFrame: hit)
                        return
                    }
                    // Empty-area click: scrub.
                    seek(at: value.location.x, width: width)
                    return
                }
                guard var d = drag else { return }
                let pxPerFrame = max(0.0001, width / Double(span))
                let raw = KeyframesMetrics.frameAt(x: value.location.x, clipStart: clip.startFrame, span: span, width: width)
                let snapped = applySnap(raw: raw, pxPerFrame: pxPerFrame, width: width)
                if snapped != d.currentFrame {
                    editor.applyMoveKeyframe(clipId: clip.id, property: property,
                                             fromFrame: d.currentFrame, toFrame: snapped)
                    d.currentFrame = snapped
                    drag = d
                }
            }
            .onEnded { value in
                if let d = drag {
                    if d.currentFrame != d.originalFrame {
                        editor.commitMoveKeyframe(clipId: clip.id)
                    } else {
                        // No-op drag: clear the drag-before snapshot so a future commit
                        // doesn't pull in stale state.
                        editor.revertClipProperty(clipId: clip.id)
                    }
                    drag = nil
                    snapState = SnapEngine.SnapState()
                    snapX = nil
                } else {
                    seek(at: value.location.x, width: width)
                }
            }
    }

    // MARK: - Snap

    private func applySnap(raw: Int, pxPerFrame: Double, width: CGFloat) -> Int {
        let targets = snapTargets()
        let candidate: Int
        if let snap = SnapEngine.findSnap(
            position: raw,
            targets: targets,
            state: &snapState,
            baseThreshold: Self.snapThresholdPixels,
            pixelsPerFrame: pxPerFrame
        ) {
            candidate = snap.frame
        } else {
            candidate = raw
        }

        let clamped = max(clip.startFrame, min(clip.endFrame, candidate))
        if clamped == candidate, candidate != raw {
            snapX = KeyframesMetrics.xForFrame(candidate, clipStart: clip.startFrame, span: span, width: width)
        } else {
            snapX = nil
        }
        return clamped
    }

    /// Snap targets pulled from the same clip: in-range playhead, clip edges, and kfs of other properties.
    private func snapTargets() -> [SnapEngine.SnapTarget] {
        var targets: [SnapEngine.SnapTarget] = []
        if clip.contains(timelineFrame: editor.currentFrame) {
            targets.append(.init(frame: editor.currentFrame, kind: .playhead))
        }
        targets.append(.init(frame: clip.startFrame, kind: .clipEdge))
        targets.append(.init(frame: clip.endFrame, kind: .clipEdge))
        for p in AnimatableProperty.allCases where p != property {
            for f in editor.keyframeFrames(clipId: clip.id, property: p) {
                targets.append(.init(frame: f, kind: .clipEdge))
            }
        }
        return targets
    }

    // MARK: - Hit testing / coords

    private func nearestKf(at x: CGFloat, width: CGFloat) -> Int? {
        var best: (frame: Int, dx: CGFloat)?
        for f in frames {
            let kx = KeyframesMetrics.xForFrame(f, clipStart: clip.startFrame, span: span, width: width)
            let dx = abs(x - kx)
            if dx <= Self.hitTolerance, dx < (best?.dx ?? .greatestFiniteMagnitude) {
                best = (f, dx)
            }
        }
        return best?.frame
    }

    private func seek(at x: CGFloat, width: CGFloat) {
        editor.seekToFrame(KeyframesMetrics.frameAt(x: x, clipStart: clip.startFrame, span: span, width: width))
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for frame: Int) -> some View {
        let current = editor.interpolation(clipId: clip.id, property: property, atFrame: frame) ?? .smooth
        Button { editor.setInterpolation(clipId: clip.id, property: property, frame: frame, interpolation: .linear) } label: {
            Label("Linear", systemImage: current == .linear ? "checkmark" : "")
        }
        Button { editor.setInterpolation(clipId: clip.id, property: property, frame: frame, interpolation: .smooth) } label: {
            Label("Smooth", systemImage: current == .smooth ? "checkmark" : "")
        }
        Button { editor.setInterpolation(clipId: clip.id, property: property, frame: frame, interpolation: .hold) } label: {
            Label("Hold", systemImage: current == .hold ? "checkmark" : "")
        }
        Divider()
        Button("Delete Keyframe", role: .destructive) {
            editor.removeKeyframe(clipId: clip.id, property: property, at: frame)
        }
    }
}

/// Right-side panel: ruler + clip strip + per-property lane rows + single playhead.
struct KeyframesPanel: View {
    let clip: Clip
    @Environment(EditorViewModel.self) private var editor
    @State private var snapX: CGFloat?

    private static let rows: [(AnimatableProperty, String)] = [
        (.position, "Position"),
        (.scale,    "Scale"),
        (.opacity,  "Opacity"),
        (.crop,     "Crop"),
    ]

    private var tint: Color { Color(nsColor: clip.sourceClipType.themeColor) }
    private var span: Int { max(1, clip.endFrame - clip.startFrame) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ClipRulerBlock(clip: clip, tint: tint, onSeek: { editor.seekToFrame($0) })
                ForEach(Self.rows, id: \.0) { row in
                    KeyframesLaneRow(
                        clip: clip,
                        property: row.0,
                        frames: editor.keyframeFrames(clipId: clip.id, property: row.0),
                        tint: tint,
                        snapX: $snapX
                    )
                    .frame(height: KeyframesMetrics.rowHeight)
                }
            }
            playheadOverlay
            snapOverlay
        }
    }

    /// Dashed yellow vertical line at the active snap x
    @ViewBuilder
    private var snapOverlay: some View {
        if let x = snapX {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.yellow), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .allowsHitTesting(false)
        }
    }

    /// Single red playhead overlay spanning the panel's full width
    private var playheadOverlay: some View {
        GeometryReader { proxy in
            if clip.contains(timelineFrame: editor.currentFrame) {
                let x = KeyframesMetrics.xForFrame(editor.currentFrame, clipStart: clip.startFrame, span: span, width: proxy.size.width)
                Canvas { ctx, size in
                    let path = CGMutablePath()
                    Playhead.appendPath(path, x: x, top: Playhead.triangleSize, bottom: size.height, triangle: true)
                    let color = Color(nsColor: Playhead.color)
                    ctx.fill(Path(path), with: .color(color))
                    ctx.stroke(Path(path), with: .color(color), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Reuses TimelineRuler.draw inside an NSView so the inspector ruler matches the main timeline.
private struct RulerView: NSViewRepresentable {
    let clipStart: Int
    let span: Int
    let fps: Int

    func makeNSView(context: Context) -> RulerNSView { RulerNSView() }
    func updateNSView(_ v: RulerNSView, context: Context) {
        v.clipStart = clipStart; v.span = span; v.fps = fps; v.needsDisplay = true
    }

    final class RulerNSView: NSView {
        var clipStart = 0
        var span = 1
        var fps = 30
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
            let pxPerFrame = Double(bounds.width) / Double(max(1, span))
            TimelineRuler.draw(
                in: bounds,
                fps: fps,
                pixelsPerFrame: pxPerFrame,
                scrollOffsetX: CGFloat(clipStart) * pxPerFrame,
                context: ctx
            )
        }
    }
}
