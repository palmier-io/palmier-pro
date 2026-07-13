import SwiftUI

struct AudioMeterView: View {
    @Environment(EditorViewModel.self) private var editor

    private static let barsWidth = AppTheme.AudioMeter.barWidth * 2
    private static let contentWidth = barsWidth + AppTheme.Spacing.xxs + AppTheme.Spacing.xs
    private static let rulerMarks = stride(
        from: AudioMeterChannelState.ceilingDb,
        through: AudioMeterChannelState.floorDb,
        by: -AppTheme.AudioMeter.rulerStepDb
    ).map { $0 }

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: AppTheme.AudioMeter.refreshInterval)) { _ in
            let display = editor.audioMeter.display()
            Canvas { context, size in
                drawChannel(display.left, x: 0, height: size.height, context: &context)
                drawChannel(display.right, x: AppTheme.AudioMeter.barWidth, height: size.height, context: &context)
                fill(
                    CGRect(
                        x: AppTheme.AudioMeter.barWidth - AppTheme.BorderWidth.thin / 2,
                        y: 0,
                        width: AppTheme.BorderWidth.thin,
                        height: size.height
                    ),
                    color: AppTheme.Background.previewCanvasColor,
                    context: &context
                )

                let rulerX = Self.barsWidth + AppTheme.Spacing.xxs
                for db in Self.rulerMarks {
                    let major = db.truncatingRemainder(dividingBy: AppTheme.AudioMeter.rulerMajorStepDb) == 0
                    fill(
                        CGRect(
                            x: rulerX,
                            y: tickY(for: db, height: size.height),
                            width: major ? AppTheme.Spacing.xs : AppTheme.BorderWidth.thick,
                            height: AppTheme.BorderWidth.hairline
                        ),
                        color: AppTheme.Text.mutedColor,
                        context: &context
                    )
                }
            }
            .frame(width: Self.contentWidth)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
            .onTapGesture { editor.audioMeter.resetClipping() }
            .help("Reset Clipping Indicators")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Master Audio Meter")
            .accessibilityValue(accessibilityValue(display))
            .accessibilityAction(named: "Reset Clipping Indicators") {
                editor.audioMeter.resetClipping()
            }
        }
        .frame(width: AppTheme.AudioMeter.panelWidth)
        .background(AppTheme.Background.baseColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(width: AppTheme.BorderWidth.thin)
        }
    }

    private func drawChannel(
        _ channel: AudioMeterChannelDisplay,
        x: CGFloat,
        height: CGFloat,
        context: inout GraphicsContext
    ) {
        let gap = AppTheme.BorderWidth.thin
        let count = max(1, Int((height + gap) / (AppTheme.BorderWidth.thin + gap)))
        let segmentHeight = (height - CGFloat(count - 1) * gap) / CGFloat(count)
        guard segmentHeight > 0 else { return }
        let activeCount = min(count, max(0, Int(ceil(normalized(channel.levelDb) * CGFloat(count)))))

        for index in 0..<count {
            let color: Color
            if channel.clipped && index == count - 1 {
                color = AppTheme.Status.errorColor
            } else if index < activeCount {
                color = segmentColor(for: decibels(at: index, count: count))
            } else {
                color = AppTheme.Background.previewCanvasColor
            }
            let y = height - CGFloat(index + 1) * segmentHeight - CGFloat(index) * gap
            fill(
                CGRect(x: x, y: y, width: AppTheme.AudioMeter.barWidth, height: segmentHeight),
                color: color,
                context: &context
            )
        }

        guard channel.peakDb > AudioMeterChannelState.floorDb else { return }
        let lineHeight = AppTheme.BorderWidth.thin
        let y = min(
            height - lineHeight,
            max(0, height * (1 - normalized(channel.peakDb)) - lineHeight / 2)
        )
        fill(
            CGRect(x: x, y: y, width: AppTheme.AudioMeter.barWidth, height: lineHeight),
            color: segmentColor(for: channel.peakDb),
            context: &context
        )
    }

    private func fill(_ rect: CGRect, color: Color, context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(color))
    }

    private func normalized(_ db: Float) -> CGFloat {
        let floor = AudioMeterChannelState.floorDb
        let ceiling = AudioMeterChannelState.ceilingDb
        return CGFloat(min(1, max(0, (db - floor) / (ceiling - floor))))
    }

    private func decibels(at index: Int, count: Int) -> Float {
        let floor = AudioMeterChannelState.floorDb
        let position = (Float(index) + 0.5) / Float(count)
        return floor + position * (AudioMeterChannelState.ceilingDb - floor)
    }

    private func segmentColor(for db: Float) -> Color {
        if db >= AppTheme.AudioMeter.redThresholdDb { return AppTheme.AudioMeter.redSegment }
        if db >= AppTheme.AudioMeter.yellowThresholdDb { return AppTheme.AudioMeter.yellowSegment }
        return AppTheme.AudioMeter.greenSegment
    }

    private func tickY(for db: Float, height: CGFloat) -> CGFloat {
        let y = height * (1 - normalized(db)) - AppTheme.BorderWidth.hairline / 2
        return min(height - AppTheme.BorderWidth.hairline, max(0, y))
    }

    private func accessibilityValue(_ display: StereoAudioMeterDisplay) -> String {
        "Left \(Int(display.left.levelDb.rounded())) dBFS, right \(Int(display.right.levelDb.rounded())) dBFS"
    }
}
