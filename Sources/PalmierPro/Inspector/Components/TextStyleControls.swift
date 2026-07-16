import SwiftUI

struct TextStyleSelection {
    let styles: [TextStyle]
    let fallback: TextStyle

    var primary: TextStyle { styles.first ?? fallback }

    func value<Value: Equatable>(_ keyPath: KeyPath<TextStyle, Value>) -> Value? {
        guard let first = styles.first else { return fallback[keyPath: keyPath] }
        let value = first[keyPath: keyPath]
        return styles.dropFirst().allSatisfy { $0[keyPath: keyPath] == value } ? value : nil
    }
}

struct TextStyleEditingActions {
    typealias Mutation = (inout TextStyle) -> Void

    let apply: (_ fitToContent: Bool, _ mutation: @escaping Mutation) -> Void
    let commit: (_ fitToContent: Bool, _ mutation: @escaping Mutation) -> Void
    let commitColor: (_ key: String, _ mutation: @escaping Mutation) -> Void
    let cancelPending: (_ key: String) -> Void
    let cancelFontPreview: (_ originalFont: String?) -> Void
}

struct TextStyleControls<AfterAlignment: View, AfterColor: View>: View {
    let selection: TextStyleSelection
    let defaults: TextStyle
    let styleExpanded: Binding<Bool>?
    let actions: TextStyleEditingActions
    @ViewBuilder let afterAlignment: () -> AfterAlignment
    @ViewBuilder let afterColor: () -> AfterColor

    @State private var outlineExpanded: Bool
    @State private var shadowExpanded: Bool
    @State private var backgroundExpanded: Bool

    init(
        selection: TextStyleSelection,
        defaults: TextStyle,
        styleExpanded: Binding<Bool>? = nil,
        groupsExpandedByDefault: Bool = true,
        actions: TextStyleEditingActions,
        @ViewBuilder afterAlignment: @escaping () -> AfterAlignment,
        @ViewBuilder afterColor: @escaping () -> AfterColor
    ) {
        self.selection = selection
        self.defaults = defaults
        self.styleExpanded = styleExpanded
        self.actions = actions
        self.afterAlignment = afterAlignment
        self.afterColor = afterColor
        _outlineExpanded = State(initialValue: groupsExpandedByDefault)
        _shadowExpanded = State(initialValue: groupsExpandedByDefault)
        _backgroundExpanded = State(initialValue: groupsExpandedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            EditorPanelGroup("Style", isExpanded: styleExpanded) {
                fontRow
                traitsRow
                numberRow(
                    label: "Size",
                    range: 12...300,
                    format: "%.0f",
                    suffix: " pt",
                    fitToContent: true,
                    keyPath: \.fontSize
                )
                numberRow(
                    label: "Tracking",
                    range: -20...100,
                    format: "%.1f",
                    suffix: " pt",
                    fitToContent: true,
                    keyPath: \.tracking
                )
                numberRow(
                    label: "Line Spacing",
                    range: -100...300,
                    format: "%.1f",
                    suffix: " pt",
                    fitToContent: true,
                    keyPath: \.lineSpacing
                )
                fontCaseRow
                alignmentRow
                afterAlignment()
                colorRow(
                    label: "Color",
                    debounceKey: "textColor",
                    keyPath: \.color
                )
                afterColor()
            }
            outlineGroup
            shadowGroup
            backgroundGroup
        }
    }

    private var fontRow: some View {
        let originalFont = selection.value(\.fontName)
        return InspectorRow(
            label: "Font",
            onReset: {
                actions.commit(true) { $0.fontName = defaults.fontName }
            }
        ) {
            FontPickerField(
                current: originalFont,
                onPreview: { name in
                    actions.apply(true) { $0.fontName = name }
                },
                onChange: { name in
                    actions.commit(true) { $0.fontName = name }
                },
                onCancel: {
                    actions.cancelFontPreview(originalFont)
                }
            )
        }
    }

    private var traitsRow: some View {
        InspectorRow(
            label: "Style",
            onReset: {
                actions.commit(true) {
                    $0.isBold = defaults.isBold
                    $0.isItalic = defaults.isItalic
                    $0.isUnderlined = defaults.isUnderlined
                    $0.isStruckThrough = defaults.isStruckThrough
                    $0.isOverlined = defaults.isOverlined
                }
            }
        ) {
            TextStyleTraitButtons(
                isBold: selection.value(\.isBold),
                isItalic: selection.value(\.isItalic),
                isUnderlined: selection.value(\.isUnderlined),
                isStruckThrough: selection.value(\.isStruckThrough),
                isOverlined: selection.value(\.isOverlined),
                onBold: { value in
                    actions.commit(true) { $0.isBold = value }
                },
                onItalic: { value in
                    actions.commit(true) { $0.isItalic = value }
                },
                onUnderline: { value in
                    actions.commit(false) { $0.isUnderlined = value }
                },
                onStrikethrough: { value in
                    actions.commit(false) { $0.isStruckThrough = value }
                },
                onOverline: { value in
                    actions.commit(false) { $0.isOverlined = value }
                }
            )
        }
    }

    private var fontCaseRow: some View {
        InspectorRow(
            label: "Font Case",
            onReset: {
                actions.commit(true) { $0.fontCase = defaults.fontCase }
            }
        ) {
            Menu {
                ForEach(TextStyle.FontCase.allCases, id: \.self) { fontCase in
                    Button(fontCase.label) {
                        actions.commit(true) { $0.fontCase = fontCase }
                    }
                }
            } label: {
                EditorMenuValue(text: selection.value(\.fontCase)?.label ?? "—")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .focusable(false)
        }
    }

    private var alignmentRow: some View {
        InspectorRow(
            label: "Alignment",
            onReset: {
                actions.commit(false) { $0.alignment = defaults.alignment }
            }
        ) {
            Picker(
                "",
                selection: Binding(
                    get: { selection.primary.alignment },
                    set: { value in actions.commit(false) { $0.alignment = value } }
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

    private var outlineGroup: some View {
        decorationGroup(
            "Outline",
            isExpanded: $outlineExpanded,
            fitToContent: true,
            enabledKeyPath: \.border.enabled,
            debounceKeys: ["outlineColor"],
            onReset: { $0.border = defaults.border }
        ) {
            colorRow(
                label: "Color",
                debounceKey: "outlineColor",
                keyPath: \.border.color
            )
            numberRow(
                label: "Width",
                range: 0...40,
                format: "%.1f",
                suffix: " pt",
                fitToContent: true,
                keyPath: \.border.width
            )
        }
    }

    private var shadowGroup: some View {
        decorationGroup(
            "Shadow",
            isExpanded: $shadowExpanded,
            fitToContent: true,
            enabledKeyPath: \.shadow.enabled,
            debounceKeys: ["shadowColor"],
            onReset: { $0.shadow = defaults.shadow }
        ) {
            colorRow(
                label: "Color",
                debounceKey: "shadowColor",
                preservesOpacity: true,
                keyPath: \.shadow.color
            )
            numberRow(
                label: "Opacity",
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                suffix: "%",
                keyPath: \.shadow.color.a
            )
            pairRow(
                label: "Offset",
                range: -200...200,
                fitToContent: true,
                xKeyPath: \.shadow.offsetX,
                yKeyPath: \.shadow.offsetY
            )
            numberRow(
                label: "Blur",
                range: 0...100,
                format: "%.1f",
                suffix: " pt",
                fitToContent: true,
                keyPath: \.shadow.blur
            )
        }
    }

    private var backgroundGroup: some View {
        decorationGroup(
            "Background",
            isExpanded: $backgroundExpanded,
            fitToContent: true,
            enabledKeyPath: \.background.enabled,
            debounceKeys: ["backgroundColor", "backgroundOutlineColor"],
            onReset: { $0.background = defaults.background }
        ) {
            colorRow(
                label: "Color",
                debounceKey: "backgroundColor",
                preservesOpacity: true,
                keyPath: \.background.color
            )
            numberRow(
                label: "Opacity",
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                suffix: "%",
                keyPath: \.background.color.a
            )
            pairRow(
                label: "Padding",
                range: 0...300,
                fitToContent: true,
                xKeyPath: \.background.paddingX,
                yKeyPath: \.background.paddingY
            )
            pairRow(
                label: "Center",
                range: -500...500,
                xKeyPath: \.background.offsetX,
                yKeyPath: \.background.offsetY
            )
            numberRow(
                label: "Corner Radius",
                range: 0...300,
                format: "%.1f",
                suffix: " pt",
                keyPath: \.background.cornerRadius
            )
            colorRow(
                label: "Outline Color",
                debounceKey: "backgroundOutlineColor",
                keyPath: \.background.outlineColor
            )
            numberRow(
                label: "Outline Width",
                range: 0...40,
                format: "%.1f",
                suffix: " pt",
                keyPath: \.background.outlineWidth
            )
        }
    }

    private func decorationGroup<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        fitToContent: Bool = false,
        enabledKeyPath: WritableKeyPath<TextStyle, Bool>,
        debounceKeys: [String],
        onReset: @escaping TextStyleEditingActions.Mutation,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let enabled = selection.value(enabledKeyPath)
        return EditorPanelGroup(
            title,
            isExpanded: isExpanded,
            onReset: {
                debounceKeys.forEach(actions.cancelPending)
                actions.commit(fitToContent, onReset)
            },
            headerAccessory: {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled ?? false },
                        set: { value in
                            actions.commit(fitToContent) {
                                $0[keyPath: enabledKeyPath] = value
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
                .accessibilityLabel(title)
            }
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                content()
            }
            .disabled(enabled != true)
            .opacity(enabled == true ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
        }
    }

    private func colorRow(
        label: String,
        debounceKey: String,
        preservesOpacity: Bool = false,
        keyPath: WritableKeyPath<TextStyle, TextStyle.RGBA>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                actions.cancelPending(debounceKey)
                actions.commit(false) {
                    if preservesOpacity {
                        $0[keyPath: keyPath].setRGB(from: defaults[keyPath: keyPath])
                    } else {
                        $0[keyPath: keyPath] = defaults[keyPath: keyPath]
                    }
                }
            }
        ) {
            ColorField(
                displayColor: selection.primary[keyPath: keyPath].swiftUIColor,
                onUserChange: { color in
                    actions.commitColor(debounceKey) {
                        let value = TextStyle.RGBA(color)
                        if preservesOpacity {
                            $0[keyPath: keyPath].setRGB(from: value)
                        } else {
                            $0[keyPath: keyPath] = value
                        }
                    }
                },
                supportsOpacity: !preservesOpacity
            )
        }
    }

    private func numberRow(
        label: String,
        range: ClosedRange<Double>,
        displayMultiplier: Double = 1,
        format: String,
        suffix: String,
        fitToContent: Bool = false,
        keyPath: WritableKeyPath<TextStyle, Double>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                actions.commit(fitToContent) {
                    $0[keyPath: keyPath] = defaults[keyPath: keyPath]
                }
            }
        ) {
            ScrubbableNumberField(
                value: selection.value(keyPath),
                range: range,
                displayMultiplier: displayMultiplier,
                format: format,
                valueSuffix: suffix,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { value in
                    actions.apply(fitToContent) { $0[keyPath: keyPath] = value }
                }
            ) { value in
                actions.commit(fitToContent) { $0[keyPath: keyPath] = value }
            }
        }
    }

    private func pairRow(
        label: String,
        range: ClosedRange<Double>,
        fitToContent: Bool = false,
        xKeyPath: WritableKeyPath<TextStyle, Double>,
        yKeyPath: WritableKeyPath<TextStyle, Double>
    ) -> some View {
        InspectorRow(
            label: label,
            onReset: {
                actions.commit(fitToContent) {
                    $0[keyPath: xKeyPath] = defaults[keyPath: xKeyPath]
                    $0[keyPath: yKeyPath] = defaults[keyPath: yKeyPath]
                }
            }
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                axisField(value: selection.value(xKeyPath), label: "X", range: range) { value, commit in
                    updateNumber(value, keyPath: xKeyPath, fitToContent: fitToContent, commit: commit)
                }
                axisField(value: selection.value(yKeyPath), label: "Y", range: range) { value, commit in
                    updateNumber(value, keyPath: yKeyPath, fitToContent: fitToContent, commit: commit)
                }
            }
            .fixedSize()
        }
    }

    private func axisField(
        value: Double?,
        label: String,
        range: ClosedRange<Double>,
        update: @escaping (_ value: Double, _ commit: Bool) -> Void
    ) -> some View {
        ScrubbableNumberField(
            value: value,
            range: range,
            format: "%.1f",
            fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
            trailingLabel: label,
            onChanged: { update($0, false) }
        ) { update($0, true) }
    }

    private func updateNumber(
        _ value: Double,
        keyPath: WritableKeyPath<TextStyle, Double>,
        fitToContent: Bool,
        commit: Bool
    ) {
        let mutation: TextStyleEditingActions.Mutation = { $0[keyPath: keyPath] = value }
        if commit {
            actions.commit(fitToContent, mutation)
        } else {
            actions.apply(fitToContent, mutation)
        }
    }
}

extension TextStyleControls where AfterAlignment == EmptyView, AfterColor == EmptyView {
    init(
        selection: TextStyleSelection,
        defaults: TextStyle,
        styleExpanded: Binding<Bool>? = nil,
        groupsExpandedByDefault: Bool = true,
        actions: TextStyleEditingActions
    ) {
        self.init(
            selection: selection,
            defaults: defaults,
            styleExpanded: styleExpanded,
            groupsExpandedByDefault: groupsExpandedByDefault,
            actions: actions,
            afterAlignment: { EmptyView() },
            afterColor: { EmptyView() }
        )
    }
}
