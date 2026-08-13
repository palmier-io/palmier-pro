import SwiftUI

struct KeyframePropertyValueFields: View {
    struct Style {
        let scalarWidth: CGFloat
        let positionWidth: CGFloat
        let fieldHeight: CGFloat
        let valueFontSize: CGFloat
        let positionLabelFontSize: CGFloat
        let positionSpacing: CGFloat
        let volumeSuffix: String

        static let inspector = Style(
            scalarWidth: AppTheme.EditorPanel.numericFieldWidth,
            positionWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
            fieldHeight: AppTheme.EditorPanel.fieldMinHeight,
            valueFontSize: AppTheme.FontSize.sm,
            positionLabelFontSize: AppTheme.FontSize.xs,
            positionSpacing: AppTheme.Spacing.sm,
            volumeSuffix: " dB"
        )
        static let timeline = Style(
            scalarWidth: AppTheme.ComponentSize.timelineKeyframeValueFieldWidth,
            positionWidth: AppTheme.ComponentSize.timelineKeyframeValueFieldWidth,
            fieldHeight: AppTheme.ComponentSize.timelineKeyframeValueFieldHeight,
            valueFontSize: AppTheme.FontSize.micro,
            positionLabelFontSize: AppTheme.FontSize.xxs,
            positionSpacing: AppTheme.Spacing.xs,
            volumeSuffix: "dB"
        )
    }

    let clips: [Clip]
    let property: AnimatableProperty
    let style: Style

    @Environment(EditorViewModel.self) private var editor
    @State private var interactionClipIds: [String]?
    @State private var interactionFrame: Int?
    @State private var detailPresented = false

    var body: some View {
        Group {
            switch property {
            case .position:
                positionFields
            case .opacity, .rotation, .scale, .volume:
                scalarField
            case .crop:
                cropControl
            }
        }
        .onDisappear {
            if property == .rotation {
                editor.rotationSnapGuidesVisible = false
            }
        }
        .onChange(of: clips.first?.id) { oldId, newId in
            if oldId != newId {
                detailPresented = false
            }
        }
    }

    private var positionFields: some View {
        let frame = editor.activeFrame
        let x = sharedClipValue(clips) { $0.topLeftAt(frame: frame).x }
        let y = sharedClipValue(clips) { $0.topLeftAt(frame: frame).y }
        return HStack(spacing: style.positionSpacing) {
            positionField(
                label: "X",
                value: x,
                multiplier: Double(editor.timeline.width),
                axis: .horizontal
            )
            positionField(
                label: "Y",
                value: y,
                multiplier: Double(editor.timeline.height),
                axis: .vertical
            )
        }
        .fixedSize()
    }

    private func positionField(
        label: String,
        value: Double?,
        multiplier: Double,
        axis: PositionAxis
    ) -> some View {
        ScrubbableNumberField(
            value: value,
            range: -10...10,
            displayMultiplier: multiplier,
            format: "%.0f",
            fieldWidth: style.positionWidth,
            fieldHeight: style.fieldHeight,
            valueFontSize: style.valueFontSize,
            trailingLabel: label,
            trailingLabelFontSize: style.positionLabelFontSize,
            onChanged: { writePosition($0, axis: axis, commit: false) },
            onInteractionStart: beginInteraction,
            onInteractionEnd: endInteraction
        ) {
            writePosition($0, axis: axis, commit: true)
        }
    }

    private var cropControl: some View {
        Button {
            if !detailPresented, editor.isPlaying {
                editor.pause()
            }
            detailPresented.toggle()
        } label: {
            Text(L10n.string("Insets"))
                .font(.system(
                    size: AppTheme.FontSize.xxs,
                    weight: AppTheme.FontWeight.medium
                ).monospacedDigit())
                .foregroundStyle(AppTheme.Accent.primary)
                .lineLimit(1)
                .frame(width: style.scalarWidth, alignment: .trailing)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .editorValueField(
                    active: detailPresented,
                    minHeight: style.fieldHeight
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $detailPresented, arrowEdge: .trailing) {
            cropEditor
                .padding(AppTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private var cropEditor: some View {
        if let clip = clips.first {
            let crop = clip.cropAt(frame: editor.activeFrame)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if editor.cropAspectLock == .free {
                    cropField(L10n.string("Left"), crop: crop, edge: .left)
                    cropField(L10n.string("Top"), crop: crop, edge: .top)
                    cropField(L10n.string("Right"), crop: crop, edge: .right)
                    cropField(L10n.string("Bottom"), crop: crop, edge: .bottom)
                } else {
                    Text(L10n.string("Use Freeform to edit individual crop insets."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Button(L10n.string("Use Freeform")) {
                        editor.cropAspectLock = .free
                    }
                }
            }
        } else {
            Text(verbatim: "—")
        }
    }

    private func cropField(
        _ label: String,
        crop: Crop,
        edge: Crop.Edge
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            ScrubbableNumberField(
                value: crop.inset(for: edge),
                range: 0...crop.maximumInset(for: edge),
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: style.scalarWidth,
                fieldHeight: style.fieldHeight,
                valueFontSize: style.valueFontSize,
                onChanged: { writeCrop($0, edge: edge, commit: false) },
                onInteractionStart: beginInteraction,
                onInteractionEnd: endInteraction
            ) {
                writeCrop($0, edge: edge, commit: true)
            }
        }
    }

    private var scalarField: some View {
        let value = sharedClipValue(clips) { scalarValue(for: $0) }
        let config = scalarConfiguration
        return ScrubbableNumberField(
            value: value,
            range: config.range,
            displayMultiplier: config.multiplier,
            format: config.format,
            valueSuffix: config.suffix,
            dragSensitivity: config.sensitivity,
            fieldWidth: style.scalarWidth,
            fieldHeight: style.fieldHeight,
            valueFontSize: style.valueFontSize,
            dragValueAdjustment: adjustedScalarValue,
            displayTextOverride: scalarDisplayText,
            onDraggingValue: handleScalarDrag,
            onChanged: { writeScalar($0, commit: false) },
            onInteractionStart: beginInteraction,
            onInteractionEnd: endInteraction
        ) {
            editor.rotationSnapGuidesVisible = false
            writeScalar($0, commit: true)
        }
    }

    private func adjustedScalarValue(_ value: Double) -> Double {
        property == .rotation ? RotationSnap.adjusted(value) : value
    }

    private func scalarDisplayText(_ value: Double) -> String? {
        property == .volume && value <= VolumeScale.floorDb
            ? "-∞\(style.volumeSuffix)"
            : nil
    }

    private func handleScalarDrag(_ value: Double) {
        guard property == .rotation else { return }
        editor.rotationSnapGuidesVisible = RotationSnap.isAxisAligned(value)
    }

    private func scalarValue(for clip: Clip) -> Double {
        switch property {
        case .opacity:
            clip.rawOpacityAt(frame: editor.activeFrame)
        case .rotation:
            clip.rotationAt(frame: editor.activeFrame)
        case .scale:
            clip.mediaType == .text
                ? clip.textStyleAt(frame: editor.activeFrame).scaledVisualStyle.fontSize
                : clip.sizeAt(frame: editor.activeFrame).width
        case .volume:
            clip.liveVolumeKfDb(at: editor.activeFrame)
                ?? VolumeScale.dbFromLinear(clip.volume)
        case .position, .crop:
            0
        }
    }

    private var scalarConfiguration: ScalarConfiguration {
        switch property {
        case .opacity:
            (0...1, 100, "%.0f", "%", 1, "Change Opacity")
        case .rotation:
            (-3600...3600, 1, "%.0f", "°", 1, "Change Rotation")
        case .scale:
            clips.allSatisfy { $0.mediaType == .text }
                ? (12...300, 1, "%.0f", " pt", 1, "Change Text Size")
                : (0.01...(.infinity), 100, "%.0f", "%", 1, "Change Scale")
        case .volume:
            (
                VolumeScale.floorDb...VolumeScale.ceilingDb,
                1, "%.1f", style.volumeSuffix, 0.3, "Change Volume"
            )
        case .position, .crop:
            (0...1, 1, "%.0f", "", 1, "Change Clip Property")
        }
    }

    private func writeScalar(_ value: Double, commit: Bool) {
        let actionName = scalarConfiguration.actionName
        guard let clipIds = resolvedInteractionClipIds(
            commit: commit,
            actionName: actionName
        ) else { return }
        switch property {
        case .rotation:
            if commit {
                editor.commitRotation(clipIds: clipIds, valueDeg: value)
            } else {
                editor.applyRotation(clipIds: clipIds, valueDeg: value)
            }
        case .opacity, .scale, .volume:
            if commit {
                editor.undo.perform(actionName) {
                    clipIds.forEach { setScalar(value, for: $0, commit: true) }
                }
            } else {
                clipIds.forEach { setScalar(value, for: $0, commit: false) }
            }
        case .position, .crop:
            break
        }
    }

    private func setScalar(_ value: Double, for clipId: String, commit: Bool) {
        switch (property, commit) {
        case (.opacity, false): editor.applyOpacity(clipId: clipId, value: value)
        case (.opacity, true): editor.commitOpacity(clipId: clipId, value: value)
        case (.scale, false):
            if editor.clipFor(id: clipId)?.mediaType == .text {
                editor.applyTextSize(clipId: clipId, value: value)
            } else {
                editor.applyScale(clipId: clipId, newScale: value)
            }
        case (.scale, true):
            if editor.clipFor(id: clipId)?.mediaType == .text {
                editor.commitTextSize(clipId: clipId, value: value)
            } else {
                editor.commitScale(clipId: clipId, newScale: value)
            }
        case (.volume, false): editor.applyVolume(clipId: clipId, valueDb: value)
        case (.volume, true): editor.commitVolume(clipId: clipId, valueDb: value)
        case (.position, _), (.rotation, _), (.crop, _): break
        }
    }

    private func writePosition(_ value: Double, axis: PositionAxis, commit: Bool) {
        guard let clipIds = resolvedInteractionClipIds(
            commit: commit,
            actionName: "Change Position"
        ) else { return }
        let x = axis == .horizontal ? value : nil
        let y = axis == .vertical ? value : nil
        if commit {
            editor.commitPositions(clipIds: clipIds, setX: x, setY: y)
        } else {
            editor.applyPositions(clipIds: clipIds, setX: x, setY: y)
        }
    }

    private func writeCrop(_ value: Double, edge: Crop.Edge, commit: Bool) {
        guard editor.cropAspectLock == .free,
              let clipIds = resolvedInteractionClipIds(
                  commit: commit,
                  actionName: "Change Crop"
              ),
              let clipId = clipIds.first,
              let clip = editor.clipFor(id: clipId) else { return }
        let frame = interactionFrame ?? editor.activeFrame
        var crop = clip.cropAt(frame: frame)
        crop.setInset(value, edge: edge)
        if commit {
            editor.commitCrop(clipId: clipId, newCrop: crop)
        } else {
            editor.applyCrop(clipId: clipId, newCrop: crop)
        }
    }

    private func beginInteraction() {
        if editor.isPlaying {
            editor.pause()
        }
        interactionClipIds = clips.map(\.id)
        interactionFrame = editor.activeFrame
    }

    private func endInteraction() {
        interactionClipIds = nil
        interactionFrame = nil
    }

    private func resolvedInteractionClipIds(
        commit: Bool,
        actionName: String
    ) -> [String]? {
        let clipIds = interactionClipIds ?? clips.map(\.id)
        guard !clipIds.isEmpty else { return nil }
        let frame = interactionFrame ?? editor.activeFrame
        let hasAnimatedTarget = clipIds.contains {
            editor.clipFor(id: $0)?.hasActiveKeyframes(for: property) == true
        }
        guard editor.activeFrame == frame || !hasAnimatedTarget else {
            if commit {
                editor.commitClipProperties(
                    clipIds: clipIds,
                    actionName: actionName
                ) { _ in }
            }
            return nil
        }
        return clipIds
    }

    private typealias ScalarConfiguration = (
        range: ClosedRange<Double>,
        multiplier: Double,
        format: String,
        suffix: String,
        sensitivity: Double,
        actionName: String
    )

    private enum PositionAxis {
        case horizontal, vertical
    }
}

enum RotationSnap {
    static let intervalDegrees = 90.0
    static let toleranceDegrees = 4.0

    static func adjusted(_ rotation: Double) -> Double {
        guard rotation.isFinite else { return rotation }
        let nearestAxis = (rotation / intervalDegrees).rounded() * intervalDegrees
        guard abs(rotation - nearestAxis) <= toleranceDegrees else { return rotation }
        return nearestAxis == 0 ? 0 : nearestAxis
    }

    static func isAxisAligned(_ rotation: Double) -> Bool {
        guard rotation.isFinite else { return false }
        return rotation.truncatingRemainder(dividingBy: intervalDegrees) == 0
    }
}
