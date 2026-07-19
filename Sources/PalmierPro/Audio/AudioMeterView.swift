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
        ZStack(alignment: .leading) {
            Canvas { context, size in
                drawBackground(size: size, context: &context)
            }

            SwiftUI.TimelineView(.animation(minimumInterval: AppTheme.AudioMeter.refreshInterval)) { _ in
                let display = editor.audioMeter.display()
                Canvas { context, size in
                    drawLevels(display, size: size, context: &context)
                }
                .accessibilityHidden(true)
            }

            Rectangle()
                .fill(AppTheme.Background.previewCanvasColor)
                .frame(width: AppTheme.BorderWidth.thin)
                .frame(maxHeight: .infinity)
                .offset(x: AppTheme.AudioMeter.barWidth - AppTheme.BorderWidth.thin / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: Self.contentWidth)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture { editor.audioMeter.resetClipping() }
        .help("Reset Clipping Indicators")
        .accessibilityRepresentation {
            AudioMeterAccessibilityRepresentation(meter: editor.audioMeter)
        }
        .frame(width: AppTheme.AudioMeter.panelWidth)
        .background(AppTheme.Background.baseColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(width: AppTheme.BorderWidth.thin)
        }
    }

    private func drawBackground(size: CGSize, context: inout GraphicsContext) {
        let layout = AudioMeterSegmentLayout(height: size.height)
        guard layout.count > 0 else { return }
        var background = Path()
        for index in 0..<layout.count {
            background.addRect(layout.segmentRect(at: index, x: 0))
            background.addRect(layout.segmentRect(at: index, x: AppTheme.AudioMeter.barWidth))
        }
        context.fill(background, with: .color(AppTheme.Background.previewCanvasColor))

        var ruler = Path()
        let rulerX = Self.barsWidth + AppTheme.Spacing.xxs
        for db in Self.rulerMarks {
            let major = db.truncatingRemainder(dividingBy: AppTheme.AudioMeter.rulerMajorStepDb) == 0
            ruler.addRect(
                CGRect(
                    x: rulerX,
                    y: layout.tickY(for: db),
                    width: major ? AppTheme.Spacing.xs : AppTheme.BorderWidth.thick,
                    height: AppTheme.BorderWidth.hairline
                )
            )
        }
        context.fill(ruler, with: .color(AppTheme.Text.mutedColor))
    }

    private func drawLevels(
        _ display: StereoAudioMeterDisplay,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let layout = AudioMeterSegmentLayout(height: size.height)
        guard layout.count > 0 else { return }
        var paths = AudioMeterLevelPaths()
        append(display.left, x: 0, layout: layout, paths: &paths)
        append(display.right, x: AppTheme.AudioMeter.barWidth, layout: layout, paths: &paths)
        paths.draw(context: &context)
    }

    private func append(
        _ channel: AudioMeterChannelDisplay,
        x: CGFloat,
        layout: AudioMeterSegmentLayout,
        paths: inout AudioMeterLevelPaths
    ) {
        let activeCount = layout.activeSegmentCount(for: channel.levelDb)
        for index in 0..<activeCount {
            let rect = layout.segmentRect(at: index, x: x)
            if channel.clipped && index == layout.count - 1 {
                paths.addClipping(rect)
            } else {
                paths.add(rect, to: AudioMeterSegmentBand(decibels: layout.decibels(at: index)))
            }
        }

        if channel.clipped && activeCount < layout.count {
            paths.addClipping(layout.segmentRect(at: layout.count - 1, x: x))
        }
        if let peak = layout.peakRect(for: channel.peakDb, x: x) {
            paths.add(peak, to: AudioMeterSegmentBand(decibels: channel.peakDb))
        }
    }

}

private struct AudioMeterAccessibilityRepresentation: View {
    let meter: AudioMeterHub
    @State private var description = "Left \(Int(AudioMeterChannelState.floorDb)) dBFS, right \(Int(AudioMeterChannelState.floorDb)) dBFS"

    var body: some View {
        Text("Master Audio Meter")
            .accessibilityValue(description)
            .accessibilityAction(named: "Reset Clipping Indicators") {
                meter.resetClipping()
            }
            .task { await updateDescription() }
    }

    private func updateDescription() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let value = Self.value(for: meter.display())
            if description != value { description = value }
            do {
                try await clock.sleep(for: AppTheme.AudioMeter.accessibilityRefreshInterval)
            } catch {
                return
            }
        }
    }

    private static func value(for display: StereoAudioMeterDisplay) -> String {
        "Left \(Int(display.left.levelDb.rounded())) dBFS, right \(Int(display.right.levelDb.rounded())) dBFS"
    }
}

struct AudioMeterSegmentLayout: Equatable {
    let height: CGFloat
    let segmentHeight: CGFloat
    let count: Int

    init(height: CGFloat) {
        let gap = AppTheme.BorderWidth.thin
        let divisor = AppTheme.BorderWidth.thin + gap
        let rawCount = (height + gap) / divisor
        guard height.isFinite, height > 0, divisor > 0,
              rawCount.isFinite, rawCount < CGFloat(Int.max) else {
            self.height = max(0, height.isFinite ? height : 0)
            segmentHeight = 0
            count = 0
            return
        }
        let count = max(1, Int(rawCount))
        let segmentHeight = (height - CGFloat(count - 1) * gap) / CGFloat(count)
        guard segmentHeight.isFinite, segmentHeight > 0 else {
            self.height = height
            self.segmentHeight = 0
            self.count = 0
            return
        }
        self.height = height
        self.segmentHeight = segmentHeight
        self.count = count
    }

    func segmentRect(at index: Int, x: CGFloat) -> CGRect {
        let y = height - CGFloat(index + 1) * segmentHeight - CGFloat(index) * AppTheme.BorderWidth.thin
        return CGRect(x: x, y: y, width: AppTheme.AudioMeter.barWidth, height: segmentHeight)
    }

    func activeSegmentCount(for decibels: Float) -> Int {
        Int(ceil(normalized(decibels) * CGFloat(count)))
    }

    func decibels(at index: Int) -> Float {
        guard count > 0 else { return AudioMeterChannelState.floorDb }
        let position = (Float(index) + 0.5) / Float(count)
        return AudioMeterChannelState.floorDb
            + position * (AudioMeterChannelState.ceilingDb - AudioMeterChannelState.floorDb)
    }

    func peakRect(for decibels: Float, x: CGFloat) -> CGRect? {
        guard decibels.isFinite, decibels > AudioMeterChannelState.floorDb, height > 0 else { return nil }
        let lineHeight = min(AppTheme.BorderWidth.thin, height)
        let y = min(height - lineHeight, max(0, height * (1 - normalized(decibels)) - lineHeight / 2))
        return CGRect(x: x, y: y, width: AppTheme.AudioMeter.barWidth, height: lineHeight)
    }

    func tickY(for decibels: Float) -> CGFloat {
        guard height > AppTheme.BorderWidth.hairline else { return 0 }
        let y = height * (1 - normalized(decibels)) - AppTheme.BorderWidth.hairline / 2
        return min(height - AppTheme.BorderWidth.hairline, max(0, y))
    }

    private func normalized(_ decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        let range = AudioMeterChannelState.ceilingDb - AudioMeterChannelState.floorDb
        return CGFloat(min(1, max(0, (decibels - AudioMeterChannelState.floorDb) / range)))
    }
}

private enum AudioMeterSegmentBand {
    case green
    case yellow
    case red

    init(decibels: Float) {
        if decibels >= AppTheme.AudioMeter.redThresholdDb {
            self = .red
        } else if decibels >= AppTheme.AudioMeter.yellowThresholdDb {
            self = .yellow
        } else {
            self = .green
        }
    }
}

private struct AudioMeterLevelPaths {
    private var green = Path()
    private var yellow = Path()
    private var red = Path()
    private var clipping = Path()
    private var hasGreen = false
    private var hasYellow = false
    private var hasRed = false
    private var hasClipping = false

    mutating func add(_ rect: CGRect, to band: AudioMeterSegmentBand) {
        switch band {
        case .green:
            green.addRect(rect)
            hasGreen = true
        case .yellow:
            yellow.addRect(rect)
            hasYellow = true
        case .red:
            red.addRect(rect)
            hasRed = true
        }
    }

    mutating func addClipping(_ rect: CGRect) {
        clipping.addRect(rect)
        hasClipping = true
    }

    func draw(context: inout GraphicsContext) {
        if hasGreen { context.fill(green, with: .color(AppTheme.AudioMeter.greenSegment)) }
        if hasYellow { context.fill(yellow, with: .color(AppTheme.AudioMeter.yellowSegment)) }
        if hasRed { context.fill(red, with: .color(AppTheme.AudioMeter.redSegment)) }
        if hasClipping { context.fill(clipping, with: .color(AppTheme.Status.errorColor)) }
    }
}
