import SwiftUI

struct TextTab: View {
    let clip: Clip
    @Environment(EditorViewModel.self) private var editor

    private var style: TextStyle { clip.textStyle ?? TextStyle() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            contentField
            InspectorSection("Typography") {
                fontRow
                sizeSlider
            }
            InspectorSection("Appearance") {
                colorRow
                opacitySlider
                backgroundRow
                borderRow
                shadowRow
            }
            InspectorSection("Layout") {
                alignmentRow
                positionSection
            }
        }
    }

    // MARK: - Controls

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
                    .fill(Color.white.opacity(AppTheme.Opacity.hint))
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
            .tint(Color.white.opacity(AppTheme.Opacity.strong))
            .fixedSize()
        }
    }

    private var backgroundRow: some View {
        toggleColorRow(
            icon: "rectangle.fill",
            label: "Background",
            enabled: style.background.enabled,
            color: style.background.color.swiftUIColor,
            debounceKey: "backgroundColor",
            setEnabled: { $0.background.enabled = $1 },
            setColor: { $0.background.color = $1 }
        )
    }

    private var borderRow: some View {
        toggleColorRow(
            icon: "a.square",
            label: "Border",
            enabled: style.border.enabled,
            color: style.border.color.swiftUIColor,
            debounceKey: "borderColor",
            setEnabled: { $0.border.enabled = $1 },
            setColor: { $0.border.color = $1 }
        )
    }

    private func toggleColorRow(
        icon: String,
        label: String,
        enabled: Bool,
        color: Color,
        debounceKey: String,
        setEnabled: @escaping (inout TextStyle, Bool) -> Void,
        setColor: @escaping (inout TextStyle, TextStyle.RGBA) -> Void
    ) -> some View {
        InspectorRow(icon: icon, label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ColorField(
                    displayColor: color,
                    onUserChange: { new in
                        editor.debouncedCommitTextStyle(clipId: clip.id, key: debounceKey) {
                            setColor(&$0, TextStyle.RGBA(new))
                        }
                    }
                )
                .opacity(enabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                .disabled(!enabled)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { new in editor.commitTextStyle(clipId: clip.id) { setEnabled(&$0, new) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color.white.opacity(AppTheme.Opacity.strong))
            }
        }
    }

    private var shadowRow: some View {
        toggleColorRow(
            icon: "square.on.square",
            label: "Shadow",
            enabled: style.shadow.enabled,
            color: style.shadow.color.swiftUIColor,
            debounceKey: "shadowColor",
            setEnabled: { $0.shadow.enabled = $1 },
            setColor: { $0.shadow.color = $1 }
        )
    }

    @ViewBuilder
    private var positionSection: some View {
        InspectorRow(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "Position") {
            InspectorPositionFields(clips: [clip])
        }
    }
}
