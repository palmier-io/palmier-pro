import SwiftUI

struct TextTab: View {
    let clip: Clip
    @Environment(EditorViewModel.self) private var editor

    private var style: TextStyle { clip.textStyle ?? TextStyle() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            contentField
            fontRow
            sizeSlider
            opacitySlider
            colorRow
            alignmentRow
            shadowSection
            positionSection
        }
    }

    // MARK: - Sections

    private var contentField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorRow(icon: "textformat", label: "Content")
            TextContentField(
                text: Binding(
                    get: { clip.textContent ?? "" },
                    set: { new in
                        editor.applyClipProperty(clipId: clip.id, rebuild: true) { $0.textContent = new }
                        editor.growTextClipToFitContent(clipId: clip.id)
                    }
                ),
                onCommit: { new in
                    editor.commitClipProperty(clipId: clip.id) { $0.textContent = new }
                    editor.growTextClipToFitContent(clipId: clip.id)
                }
            )
            .frame(minHeight: 80)
            .padding(AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.06))
            )
        }
    }

    private var fontRow: some View {
        InspectorRow(icon: "character", label: "Font") {
            FontPickerField(current: style.fontName) { newName in
                editor.commitTextStyle(clipId: clip.id) { $0.fontName = newName }
                editor.growTextClipToFitContent(clipId: clip.id)
            }
        }
    }

    private var sizeSlider: some View {
        InspectorSlider(
            icon: "textformat.size",
            label: "Size",
            value: style.fontSize,
            range: 12...300,
            displayMultiplier: 1,
            valueSuffix: " pt",
            format: "%.0f",
            onChanged: { newVal in
                editor.applyTextStyle(clipId: clip.id) { $0.fontSize = newVal }
                editor.growTextClipToFitContent(clipId: clip.id)
            }
        ) { newVal in
            editor.commitTextStyle(clipId: clip.id) { $0.fontSize = newVal }
            editor.growTextClipToFitContent(clipId: clip.id)
        }
    }

    private var opacitySlider: some View {
        InspectorSlider(
            icon: "circle.lefthalf.filled",
            label: "Opacity",
            value: clip.opacity,
            range: 0...1,
            displayMultiplier: 100,
            valueSuffix: "%",
            format: "%.0f",
            onChanged: { newVal in
                editor.applyClipProperty(clipId: clip.id) { $0.opacity = newVal }
            }
        ) { newVal in
            editor.commitClipProperty(clipId: clip.id) { $0.opacity = newVal }
        }
    }

    private var colorRow: some View {
        InspectorRow(icon: "paintpalette", label: "Color") {
            ColorField(
                displayColor: style.color.swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitTextStyle(clipId: clip.id, key: "textColor") {
                        $0.color = TextStyle.RGBA(new)
                    }
                }
            )
        }
    }

    private var alignmentRow: some View {
        InspectorRow(icon: "text.alignleft", label: "Alignment") {
            Picker(
                "",
                selection: Binding(
                    get: { style.alignment },
                    set: { new in
                        editor.commitTextStyle(clipId: clip.id) { $0.alignment = new }
                    }
                )
            ) {
                Image(systemName: "text.alignleft").tag(TextStyle.Alignment.left)
                Image(systemName: "text.aligncenter").tag(TextStyle.Alignment.center)
                Image(systemName: "text.alignright").tag(TextStyle.Alignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.white.opacity(0.5))
            .fixedSize()
        }
    }

    @ViewBuilder
    private var shadowSection: some View {
        let shadow = style.shadow

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorRow(icon: "square.on.square", label: "Shadow") {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { shadow.enabled },
                        set: { new in
                            editor.commitTextStyle(clipId: clip.id) { $0.shadow.enabled = new }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.white.opacity(0.5))
            }

            if shadow.enabled {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(width: 16, alignment: .leading)
                        Text("Color")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        ColorField(
                            displayColor: shadow.color.swiftUIColor,
                            onUserChange: { new in
                                editor.debouncedCommitTextStyle(clipId: clip.id, key: "shadowColor") {
                                    $0.shadow.color = TextStyle.RGBA(new)
                                }
                            }
                        )
                    }

                    InspectorSlider(
                        icon: "drop",
                        label: "Blur",
                        value: shadow.blur,
                        range: 0...40,
                        displayMultiplier: 1,
                        valueSuffix: " pt",
                        format: "%.0f",
                        onChanged: { newVal in
                            editor.applyTextStyle(clipId: clip.id) { $0.shadow.blur = newVal }
                        }
                    ) { newVal in
                        editor.commitTextStyle(clipId: clip.id) { $0.shadow.blur = newVal }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1)
                        .padding(.leading, 7)
                }
            }
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        let tl = clip.transform.topLeft
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            InspectorRow(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Position") {
                Button {
                    editor.commitClipProperty(clipId: clip.id) {
                        $0.transform.x = 0
                        $0.transform.y = 0
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: 22, height: 22)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Reset position")
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                InspectorNumberField(label: "X", value: tl.x * canvasW) { newX in
                    editor.commitClipProperty(clipId: clip.id) {
                        let old = $0.transform.topLeft
                        $0.transform = Transform(topLeft: (newX / canvasW, old.y), width: $0.transform.width, height: $0.transform.height)
                    }
                }
                InspectorNumberField(label: "Y", value: tl.y * canvasH) { newY in
                    editor.commitClipProperty(clipId: clip.id) {
                        let old = $0.transform.topLeft
                        $0.transform = Transform(topLeft: (old.x, newY / canvasH), width: $0.transform.width, height: $0.transform.height)
                    }
                }
            }
        }
    }
}
