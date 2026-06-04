import SwiftUI

struct CaptionTab: View {
    @Environment(EditorViewModel.self) var editor

    @State private var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
    @State private var center = AppTheme.Caption.defaultCenter
    @State private var isGenerating = false
    @State private var note: String?
    @State private var sourceSnapshot: [String] = []

    private static let previewText = "Captions will look like this"

    private var aspect: CGFloat { CGFloat(editor.timeline.width) / CGFloat(max(1, editor.timeline.height)) }

    private var liveTargets: [String] {
        let sel = editor.selectedClipIds
        guard !sel.isEmpty else { return [] }
        return editor.captionTargets(ids: Array(sel)).map(\.id)
    }
    private var allTargetCount: Int { editor.captionTargets(ids: []).count }
    private var effectiveCount: Int { sourceSnapshot.isEmpty ? allTargetCount : sourceSnapshot.count }

    private var sourceSummary: String {
        if !sourceSnapshot.isEmpty { return "Selected · \(sourceSnapshot.count)" }
        if allTargetCount == 0 { return "No audio" }
        return "All audio · \(allTargetCount)"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        sourceSection
                        styleSection
                        placementSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.lg)
                    .padding(.bottom, AppTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: "Transcribing…", size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .onAppear { sourceSnapshot = liveTargets }
        .onChange(of: editor.selectedClipIds) { _, _ in
            let targets = liveTargets
            if !targets.isEmpty || editor.focusedPanel != .media { sourceSnapshot = targets }
        }
    }

    private var sourceSection: some View {
        InspectorSection("Source") {
            InspectorRow(
                icon: "waveform",
                label: "Audio",
                labelHelp: "Uses all audio and video clips by default. Select clips on the timeline to transcribe only those."
            ) { valueText(sourceSummary) }
            InspectorRow(icon: "globe", label: "Language") { valueText("Auto-detect") }
        }
    }

    private var styleSection: some View {
        InspectorSection("Style") {
            InspectorRow(icon: "character", label: "Font") {
                FontPickerField(current: style.fontName, onPreview: { style.fontName = $0 }, onChange: { style.fontName = $0 }, onCancel: {})
            }
            InspectorRow(icon: "textformat.size", label: "Size") {
                ScrubbableNumberField(
                    value: style.fontSize,
                    range: AppTheme.Caption.minFontSize...AppTheme.Caption.maxFontSize,
                    format: "%.0f",
                    valueSuffix: " pt",
                    onChanged: { style.fontSize = $0 }
                ) { style.fontSize = $0 }
            }
            InspectorRow(icon: "paintpalette", label: "Color") {
                ColorField(displayColor: style.color.swiftUIColor, onUserChange: { style.color = TextStyle.RGBA($0) })
            }
            InspectorRow(icon: "rectangle.fill", label: "Background") {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ColorField(displayColor: style.background.color.swiftUIColor) {
                        style.background.color = TextStyle.RGBA($0)
                    }
                    .opacity(style.background.enabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                    .disabled(!style.background.enabled)
                    Toggle("", isOn: $style.background.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
                }
            }
        }
    }

    private var placementSection: some View {
        InspectorSection("Placement") {
            previewBox
            HStack(spacing: AppTheme.Spacing.mdLg) {
                Spacer(minLength: AppTheme.Spacing.xs)
                posField("X", value: center.x) { center.x = $0 }
                posField("Y", value: center.y) { center.y = $0 }
            }
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
    }

    private var previewBox: some View {
        ZStack {
            AppTheme.Background.previewCanvasColor
            centerGuides
            GeometryReader { geo in
                let canvasW = CGFloat(max(1, editor.timeline.width))
                let canvasH = CGFloat(max(1, editor.timeline.height))
                let natural = TextLayout.naturalSize(
                    content: Self.previewText,
                    style: style,
                    maxWidth: canvasW * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
                    canvasHeight: canvasH
                )
                let scale = geo.size.height / TextLayout.referenceCanvasHeight
                let boxWidth = natural.width / canvasW * geo.size.width
                let boxHeight = natural.height / canvasH * geo.size.height
                Text(Self.previewText)
                    .font(Font(style.resolvedFont(size: CGFloat(style.fontSize * style.fontScale) * scale)))
                    .foregroundStyle(style.color.swiftUIColor)
                    .frame(width: boxWidth, height: boxHeight)
                    .background(style.background.enabled ? style.background.color.swiftUIColor : Color.clear)
                    .overlay {
                        if style.border.enabled {
                            Rectangle().stroke(style.border.color.swiftUIColor, lineWidth: AppTheme.BorderWidth.thin * scale)
                        }
                    }
                    .position(x: geo.size.width * center.x, y: geo.size.height * center.y)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: AppTheme.ComponentSize.captionPreviewMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var centerGuides: some View {
        GeometryReader { geo in
            let guide = AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.prominent)
            ZStack {
                if center.x == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: AppTheme.BorderWidth.hairline, height: geo.size.height)
                }
                if center.y == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: geo.size.width, height: AppTheme.BorderWidth.hairline)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func snapCenter(_ v: Double) -> CGFloat {
        let centerValue = Double(AppTheme.Caption.centerSnapValue)
        return CGFloat(abs(v - centerValue) < AppTheme.Caption.centerSnapThreshold ? centerValue : v)
    }

    private func posField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ScrubbableNumberField(
                value: Double(value),
                range: AppTheme.Caption.minPosition...AppTheme.Caption.maxPosition,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                onChanged: { onChange(snapCenter($0)) }
            ) { onChange(snapCenter($0)) }
        }
    }

    private var generateBar: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if let note {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: generate) {
                Text("Generate Captions")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Background.baseColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
                    .opacity(effectiveCount == 0 ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            }
            .buttonStyle(.plain).focusable(false)
            .disabled(effectiveCount == 0 || isGenerating)
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func generate() {
        note = nil
        let request = EditorViewModel.CaptionRequest(sourceClipIds: sourceSnapshot, style: style, center: center)
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                let ids = try await editor.generateCaptions(for: request)
                if ids.isEmpty { note = "No speech detected." }
            } catch {
                note = error.localizedDescription
            }
        }
    }
}
