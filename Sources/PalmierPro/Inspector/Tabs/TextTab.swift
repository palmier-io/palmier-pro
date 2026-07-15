import SwiftUI

struct TextTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private static let defaults = TextStyle()

    private var clip: Clip { clips[0] }
    private var clipIds: [String] { clips.map(\.id) }
    private var isBatch: Bool { clips.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            contentField
            TextStyleControls(
                selection: TextStyleSelection(
                    styles: clips.map { $0.textStyle ?? Self.defaults },
                    fallback: Self.defaults
                ),
                defaults: Self.defaults,
                actions: styleActions,
                afterAlignment: { positionSection },
                afterColor: { opacitySlider }
            )
        }
    }

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

    private var opacitySlider: some View {
        InspectorRow(
            label: "Opacity",
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) {
                    $0.opacity = 1
                    $0.opacityTrack = nil
                }
            }
        ) {
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

    @ViewBuilder
    private var positionSection: some View {
        InspectorRow(
            label: "Position",
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) {
                    $0.transform.centerX = Transform().centerX
                    $0.transform.centerY = Transform().centerY
                    $0.positionTrack = nil
                }
            }
        ) {
            InspectorPositionFields(clips: clips)
        }
    }

    private var styleActions: TextStyleEditingActions {
        TextStyleEditingActions(
            apply: { fitToContent, mutation in
                editor.applyTextStyles(
                    clipIds: clipIds,
                    fitToContent: fitToContent,
                    mutation
                )
            },
            commit: { fitToContent, mutation in
                editor.commitTextStyles(
                    clipIds: clipIds,
                    fitToContent: fitToContent,
                    mutation
                )
            },
            commitColor: { key, mutation in
                editor.debouncedCommitTextStyles(clipIds: clipIds, key: key, mutation)
            },
            cancelPending: { editor.cancelDebouncedCommit(key: $0) },
            cancelFontPreview: { _ in
                for id in clipIds { editor.revertClipProperty(clipId: id) }
            }
        )
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
        InspectorRow(
            label: "Highlight",
            onReset: {
                editor.cancelDebouncedCommit(key: "textHighlight")
                editor.commitClipProperties(clipIds: targetIds) {
                    guard var animation = $0.textAnimation else { return }
                    animation.highlight = TextAnimation.defaultHighlight
                    $0.textAnimation = animation
                }
            }
        ) {
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
