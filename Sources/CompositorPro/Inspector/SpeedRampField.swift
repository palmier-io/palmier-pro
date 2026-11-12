import SwiftUI

/// Speed over a clip's duration as an editable two-row curve.
///
/// The clip's own length is the x axis, so the field stays readable at inspector width and needs
/// no time ruler. Rows are clip-relative frames; the curve previews the real sampled rate.
struct SpeedRampField: View {
    let clip: Clip
    let onCommit: ([SpeedRampRow]) -> Void

    struct SpeedRampRow: Identifiable, Equatable {
        var id: Int { frame }
        var frame: Int
        var speed: Double
    }

    @State private var startSpeed: Double = 1
    @State private var endSpeed: Double = 1

    private var span: Double { max(1, Double(clip.durationFrames)) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(verbatim: L10n.string("Start"))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(Color(nsColor: AppTheme.Text.secondary))
                    .frame(width: AppTheme.EditorPanel.rampLabelWidth, alignment: .leading)
                ScrubbableNumberField(
                    value: startSpeed,
                    range: SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed,
                    format: "%.2f",
                    valueSuffix: "x",
                    dragSensitivity: 0.01,
                    fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                    onChanged: { startSpeed = $0 },
                    onInteractionEnd: { commit() },
                    onCommit: { startSpeed = $0; commit() }
                )
                Text(verbatim: L10n.string("End"))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(Color(nsColor: AppTheme.Text.secondary))
                ScrubbableNumberField(
                    value: endSpeed,
                    range: SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed,
                    format: "%.2f",
                    valueSuffix: "x",
                    dragSensitivity: 0.01,
                    fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                    onChanged: { endSpeed = $0 },
                    onInteractionEnd: { commit() },
                    onCommit: { endSpeed = $0; commit() }
                )
            }
            SpeedRampCurve(
                durationFrames: clip.durationFrames,
                startSpeed: startSpeed,
                endSpeed: endSpeed
            )
            .frame(height: AppTheme.EditorPanel.rampCurveHeight)
        }
        .onAppear { syncFromClip() }
        .onChange(of: clip.speedTrack) { _, _ in syncFromClip() }
    }

    private func syncFromClip() {
        let map = clip.timeMap
        startSpeed = map.speed(atOffset: 0)
        endSpeed = map.speed(atOffset: clip.durationFrames)
    }

    private func commit() {
        let last = max(0, clip.durationFrames - 1)
        onCommit([
            SpeedRampRow(frame: 0, speed: startSpeed),
            SpeedRampRow(frame: last, speed: endSpeed),
        ])
    }
}

/// Read-only preview of the rate curve. Dragging is handled by the two number fields above,
/// which keeps the frame math in the domain layer instead of here.
private struct SpeedRampCurve: View {
    let durationFrames: Int
    let startSpeed: Double
    let endSpeed: Double

    var body: some View {
        Canvas { context, size in
            let peak = max(startSpeed, endSpeed, 0.01)
            var path = Path()
            for step in 0 ... 40 {
                let t = Double(step) / 40
                let speed = startSpeed + (endSpeed - startSpeed) * t
                let x = t * size.width
                let y = size.height * (1 - min(speed / peak, 1))
                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(Color(nsColor: AppTheme.Text.secondary)), lineWidth: AppTheme.BorderWidth.thin)
        }
        .accessibilityLabel(L10n.string("Speed Ramp"))
        .accessibilityValue(
            String(format: "%.2f%@ → %.2f%@", startSpeed, "x", endSpeed, "x")
        )
    }
}
