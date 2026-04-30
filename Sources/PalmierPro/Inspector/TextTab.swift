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
            shadowSection
            alignmentRow
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
                        editor.fitTextClipToContent(clipId: clip.id)
                    }
                ),
                onCommit: { new in
                    editor.commitClipProperty(clipId: clip.id) { $0.textContent = new }
                    editor.fitTextClipToContent(clipId: clip.id)
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
            FontPickerField(
                current: style.fontName,
                onPreview: { name in
                    editor.applyTextStyle(clipId: clip.id) { $0.fontName = name }
                },
                onChange: { newName in
                    editor.commitTextStyle(clipId: clip.id) { $0.fontName = newName }
                    editor.fitTextClipToContent(clipId: clip.id)
                },
                onCancel: {
                    editor.revertClipProperty(clipId: clip.id)
                }
            )
        }
    }

    private var sizeSlider: some View {
        InspectorRow(icon: "textformat.size", label: "Size") {
            ScrubbableNumberField(
                value: style.fontSize,
                range: 12...300,
                format: "%.0f",
                valueSuffix: " pt",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyTextStyle(clipId: clip.id) { $0.fontSize = newVal }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            ) { newVal in
                editor.commitTextStyle(clipId: clip.id) { $0.fontSize = newVal }
                editor.fitTextClipToContent(clipId: clip.id)
            }
        }
    }

    private var opacitySlider: some View {
        InspectorRow(icon: "circle.lefthalf.filled", label: "Opacity") {
            ScrubbableNumberField(
                value: clip.opacity,
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: 50,
                onChanged: { newVal in
                    editor.applyClipProperty(clipId: clip.id) { $0.opacity = newVal }
                }
            ) { newVal in
                editor.commitClipProperty(clipId: clip.id) { $0.opacity = newVal }
            }
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
                .controlSize(.mini)
                .tint(Color.white.opacity(0.5))
            }

            if shadow.enabled {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xs) {
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

                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text("Blur")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        ScrubbableNumberField(
                            value: shadow.blur,
                            range: 0...40,
                            format: "%.0f",
                            valueSuffix: " pt",
                            fieldWidth: 50,
                            onChanged: { newVal in
                                editor.applyTextStyle(clipId: clip.id) { $0.shadow.blur = newVal }
                            }
                        ) { newVal in
                            editor.commitTextStyle(clipId: clip.id) { $0.shadow.blur = newVal }
                        }
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
        InspectorRow(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Position") {
            InspectorPositionFields(clips: [clip])
        }
    }
}
