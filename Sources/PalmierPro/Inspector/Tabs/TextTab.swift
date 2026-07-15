import SwiftUI

struct TextTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private var clip: Clip { clips[0] }
    private var clipIds: [String] { clips.map(\.id) }
    private var isBatch: Bool { clips.count > 1 }
    private var style: TextStyle { clip.textStyle ?? TextStyle() }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            contentField
            EditorPanelGroup("Typography") {
                fontRow
                styleRow
                sizeSlider
            }
            EditorPanelGroup("Appearance") {
                colorRow
                opacitySlider
                backgroundRow
                borderRow
                shadowRow
            }
            EditorPanelGroup("Layout") {
                alignmentRow
                positionSection
            }
        }
    }

    // MARK: - Controls

    private var contentField: some View {
        EditorPanelGroup("Text") {
            TextContentField(
                text: Binding(
                    get: { clip.textContent ?? "" },
                    set: { new in
                        guard !isBatch else { return }
                        editor.applyClipProperty(clipId: clip.id, rebuild: true) { $0.textContent = new }
                        editor.fitTextClipToContent(clipId: clip.id)
                    }
                ),
                onCommit: { new in
                    guard !isBatch else { return }
                    editor.commitClipProperty(clipId: clip.id) { $0.textContent = new }
                    editor.fitTextClipToContent(clipId: clip.id)
                }
            )
            .disabled(isBatch)
            .opacity(isBatch ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            .frame(minHeight: AppTheme.EditorPanel.textEditorMinHeight)
            .padding(AppTheme.Spacing.smMd)
            .editorValueField()
        }
    }

    private var fontRow: some View {
        InspectorRow(label: "Font") {
            FontPickerField(
                current: sharedTextStyleValue { $0.fontName },
                onPreview: { name in
                    editor.applyTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontName = name }
                },
                onChange: { newName in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontName = newName }
                },
                onCancel: {
                    for id in clipIds { editor.revertClipProperty(clipId: id) }
                }
            )
        }
    }

    private var styleRow: some View {
        InspectorRow(label: "Style") {
            TextStyleTraitButtons(
                isBold: sharedTextStyleValue { $0.isBold },
                isItalic: sharedTextStyleValue { $0.isItalic },
                onBold: { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.isBold = new }
                },
                onItalic: { new in
                    editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.isItalic = new }
                }
            )
        }
    }

    private var sizeSlider: some View {
        InspectorRow(label: "Size") {
            ScrubbableNumberField(
                value: sharedTextStyleValue { $0.fontSize },
                range: 12...300,
                format: "%.0f",
                valueSuffix: " pt",
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newVal in
                    editor.applyTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontSize = newVal }
                }
            ) { newVal in
                editor.commitTextStyles(clipIds: clipIds, fitToContent: true) { $0.fontSize = newVal }
            }
        }
    }

    private var opacitySlider: some View {
        InspectorRow(label: "Opacity") {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { $0.opacity },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newVal in
                    editor.applyClipProperties(clipIds: clipIds) { $0.opacity = newVal }
                }
            ) { newVal in
                editor.commitClipProperties(clipIds: clipIds) { $0.opacity = newVal }
            }
        }
    }

    private var colorRow: some View {
        InspectorRow(label: "Color") {
            ColorField(
                displayColor: style.color.swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitTextStyles(clipIds: clipIds, key: "textColor") {
                        $0.color = TextStyle.RGBA(new)
                    }
                }
            )
        }
    }

    private var alignmentRow: some View {
        InspectorRow(label: "Alignment") {
            Picker(
                "",
                selection: Binding(
                    get: { style.alignment },
                    set: { new in
                        editor.commitTextStyles(clipIds: clipIds) { $0.alignment = new }
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
            label: "Outline",
            enabled: style.border.enabled,
            color: style.border.color.swiftUIColor,
            debounceKey: "borderColor",
            setEnabled: { $0.border.enabled = $1 },
            setColor: { $0.border.color = $1 }
        )
    }

    private func toggleColorRow(
        label: String,
        enabled: Bool,
        color: Color,
        debounceKey: String,
        setEnabled: @escaping (inout TextStyle, Bool) -> Void,
        setColor: @escaping (inout TextStyle, TextStyle.RGBA) -> Void
    ) -> some View {
        InspectorRow(label: label) {
            ToggleColorControl(
                label: label,
                isOn: Binding(
                    get: { enabled },
                    set: { new in editor.commitTextStyles(clipIds: clipIds) { setEnabled(&$0, new) } }
                ),
                color: color,
                onColorChange: { new in
                    editor.debouncedCommitTextStyles(clipIds: clipIds, key: debounceKey) {
                        setColor(&$0, TextStyle.RGBA(new))
                    }
                }
            )
        }
    }

    private var shadowRow: some View {
        toggleColorRow(
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
        InspectorRow(label: "Position") {
            InspectorPositionFields(clips: clips)
        }
    }

    private func sharedTextStyleValue<T: Equatable>(_ extract: (TextStyle) -> T) -> T? {
        sharedClipValue(clips) { extract($0.textStyle ?? TextStyle()) }
    }
}

struct TextAnimateTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private var clip: Clip { clips[0] }
    private var targetIds: [String] {
        var seen = Set<String>()
        return clips.flatMap { editor.captionGroupTextClipIds(for: $0.id) }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        let anim = clip.textAnimation ?? TextAnimation()
        EditorPanelGroup("Animation") {
            CaptionPresetGallery(
                selection: Binding(
                    get: { anim.preset },
                    set: { new in setAnim { $0.preset = new } }
                ),
                highlight: anim.highlight
            )
            if anim.preset.usesHighlight { highlightRow(anim) }
        }
    }

    private func setAnim(_ modify: (inout TextAnimation) -> Void) {
        var a = clip.textAnimation ?? TextAnimation()
        modify(&a)
        let value: TextAnimation? = a.preset == .none ? nil : a
        editor.cancelDebouncedCommit(key: "textHighlight")
        editor.commitClipProperties(clipIds: targetIds) { $0.textAnimation = value }
    }

    private func highlightRow(_ anim: TextAnimation) -> some View {
        InspectorRow(label: "Highlight") {
            ColorField(
                displayColor: (anim.highlight ?? TextAnimation.defaultHighlight).swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitClipProperties(clipIds: targetIds, key: "textHighlight") {
                        guard var a = $0.textAnimation, a.preset.usesHighlight else { return }
                        a.highlight = TextStyle.RGBA(new)
                        $0.textAnimation = a
                    }
                }
            )
        }
    }
}
