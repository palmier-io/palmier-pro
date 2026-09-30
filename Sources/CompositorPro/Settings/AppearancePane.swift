import SwiftUI

struct AppearancePane: View {
    @Bindable private var appearance = AppAppearanceStore.shared
    @Bindable private var workspaceLayout = WorkspaceLayoutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsGroup(title: L10n.string("Theme")) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
                    ForEach(AppAppearance.allCases) { option in
                        SettingsPreviewCard(
                            label: option.label,
                            shortcutLabel: nil,
                            isSelected: appearance.selection == option,
                            accessibilityLabel: appearanceAccessibilityLabel(option),
                            action: { appearance.selection = option }
                        ) {
                            AppearancePreview(option: option)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            SettingsGroup(title: L10n.string("Workspace layout")) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
                    ForEach(LayoutPreset.allCases) { preset in
                        SettingsPreviewCard(
                            label: preset.label,
                            shortcutLabel: preset.shortcutLabel,
                            isSelected: workspaceLayout.selection == preset,
                            accessibilityLabel: workspaceAccessibilityLabel(preset),
                            action: { workspaceLayout.selection = preset }
                        ) {
                            WorkspaceLayoutPreview(preset: preset)
                        }
                        .keyboardShortcut(KeyEquivalent(preset.shortcutKey), modifiers: .command)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            SettingsSection(title: L10n.string("Timeline colors")) {
                TimelineColorsPane()
            }
        }
    }

    private func appearanceAccessibilityLabel(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: L10n.string("System appearance")
        case .light: L10n.string("Light appearance")
        case .dark: L10n.string("Dark appearance")
        }
    }

    private func workspaceAccessibilityLabel(_ layout: LayoutPreset) -> String {
        switch layout {
        case .default: L10n.string("Default workspace layout")
        case .media: L10n.string("Media workspace layout")
        case .vertical: L10n.string("Vertical workspace layout")
        }
    }
}

private struct SettingsPreviewCard<Preview: View>: View {
    let label: String
    let shortcutLabel: String?
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppTheme.Spacing.smMd) {
                preview()
                    .aspectRatio(1.5, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(
                                borderColor,
                                lineWidth: isSelected ? AppTheme.BorderWidth.thick : AppTheme.BorderWidth.thin
                            )
                    }

                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string(key: label))
                        .foregroundStyle(isSelected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)

                    if let shortcutLabel {
                        Text(shortcutLabel)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? L10n.string("Selected") : L10n.string("Not selected"))
    }

    private var borderColor: Color {
        if isSelected { return AppTheme.Accent.primary }
        return isHovering ? AppTheme.Border.dividerColor : AppTheme.Border.subtleColor
    }
}

private struct WorkspaceLayoutPreview: View {
    let preset: LayoutPreset

    var body: some View {
        GeometryReader { geometry in
            let gap = max(geometry.size.width * 0.012, AppTheme.BorderWidth.thin)

            ZStack {
                AppTheme.Background.surfaceColor

                Group {
                    switch preset {
                    case .default:
                        VStack(spacing: gap) {
                            HStack(spacing: gap) {
                                LayoutPanelPreview(kind: .media)
                                    .frame(width: geometry.size.width * 0.24)
                                LayoutPanelPreview(kind: .preview)
                                LayoutPanelPreview(kind: .inspector)
                                    .frame(width: geometry.size.width * 0.22)
                            }
                            LayoutPanelPreview(kind: .timeline)
                                .frame(height: geometry.size.height * 0.29)
                        }
                    case .media:
                        HStack(spacing: gap) {
                            LayoutPanelPreview(kind: .media)
                                .frame(width: geometry.size.width * 0.28)
                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    LayoutPanelPreview(kind: .preview)
                                    LayoutPanelPreview(kind: .inspector)
                                        .frame(width: geometry.size.width * 0.20)
                                }
                                LayoutPanelPreview(kind: .timeline)
                                    .frame(height: geometry.size.height * 0.39)
                            }
                        }
                    case .vertical:
                        HStack(spacing: gap) {
                            VStack(spacing: gap) {
                                HStack(spacing: gap) {
                                    LayoutPanelPreview(kind: .media)
                                    LayoutPanelPreview(kind: .inspector)
                                }
                                LayoutPanelPreview(kind: .timeline)
                                    .frame(height: geometry.size.height * 0.39)
                            }
                            LayoutPanelPreview(kind: .preview)
                        }
                    }
                }
                .padding(geometry.size.width * 0.04)
            }
        }
    }
}

private struct LayoutPanelPreview: View {
    private enum Metrics {
        static let inspectorLineHeight: CGFloat = 2
        static let minimumTrackSpacing: CGFloat = 1
    }

    enum Kind {
        case media
        case preview
        case inspector
        case timeline
    }

    let kind: Kind
    @Bindable private var timelineColors = TimelineClipColorStore.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                panelBackground

                switch kind {
                case .media:
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.xxs), count: 2),
                        spacing: AppTheme.Spacing.xxs
                    ) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(AppTheme.Text.mutedColor.opacity(AppTheme.Opacity.moderate))
                                .aspectRatio(1.25, contentMode: .fit)
                        }
                    }
                    .padding(max(geometry.size.width * 0.10, AppTheme.Spacing.xs))
                case .preview:
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(AppTheme.Background.previewCanvasColor.opacity(AppTheme.Opacity.prominent))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .padding(max(geometry.size.width * 0.08, AppTheme.Spacing.xs))
                case .inspector:
                    VStack(alignment: .leading, spacing: max(geometry.size.height * 0.10, AppTheme.Spacing.xxs)) {
                        ForEach(0..<4, id: \.self) { row in
                            Capsule()
                                .fill(row == 0 ? AppTheme.Text.mutedColor : AppTheme.Border.dividerColor)
                                .frame(
                                    width: geometry.size.width * (row == 0 ? 0.58 : 0.78),
                                    height: Metrics.inspectorLineHeight
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(max(geometry.size.width * 0.12, AppTheme.Spacing.xs))
                case .timeline:
                    ZStack {
                        VStack(spacing: max(geometry.size.height * 0.08, Metrics.minimumTrackSpacing)) {
                            ForEach([TimelineClipColor.text, .video, .audio]) { clipKind in
                                Capsule()
                                    .fill(timelineColors.color(for: clipKind).opacity(AppTheme.Opacity.high))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, max(geometry.size.width * 0.05, AppTheme.Spacing.xs))
                        .padding(.vertical, max(geometry.size.height * 0.16, AppTheme.Spacing.xxs))

                        Rectangle()
                            .fill(Color(nsColor: Playhead.color))
                            .frame(width: AppTheme.BorderWidth.thin)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            }
        }
    }

    private var panelBackground: Color {
        switch kind {
        case .preview: AppTheme.Background.baseColor
        case .media, .inspector: AppTheme.Background.prominentColor
        case .timeline: AppTheme.Background.raisedColor
        }
    }
}

private struct AppearancePreview: View {
    let option: AppAppearance

    var body: some View {
        ZStack {
            switch option {
            case .system:
                AppearancePreviewScene(palette: .light)
                AppearancePreviewScene(palette: .dark)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.white
                        }
                    }
            case .light:
                AppearancePreviewScene(palette: .light)
            case .dark:
                AppearancePreviewScene(palette: .dark)
            }
        }
    }
}

private struct AppearancePreviewScene: View {
    let palette: AppearancePreviewPalette

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack(alignment: .bottom) {
                palette.canvas

                VStack(spacing: height * 0.045) {
                    Capsule()
                        .fill(palette.strongLine)
                        .frame(width: width * 0.28, height: max(height * 0.045, 3))
                    Capsule()
                        .fill(palette.line)
                        .frame(width: width * 0.48, height: max(height * 0.025, 2))
                    Spacer(minLength: 0)
                }
                .padding(.top, height * 0.18)

                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { row in
                        VStack(alignment: .leading, spacing: height * 0.035) {
                            Capsule()
                                .fill(palette.strongLine)
                                .frame(width: width * 0.28, height: max(height * 0.045, 3))
                            Capsule()
                                .fill(palette.line)
                                .frame(width: width * 0.45, height: max(height * 0.025, 2))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, width * 0.08)
                        .frame(maxHeight: .infinity)

                        if row < 2 {
                            Rectangle()
                                .fill(palette.divider)
                                .frame(height: AppTheme.BorderWidth.hairline)
                        }
                    }
                }
                .frame(width: width * 0.78, height: height * 0.62)
                .background(palette.panel)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: AppTheme.Radius.md,
                        topTrailingRadius: AppTheme.Radius.md
                    )
                )
            }
        }
    }
}

private struct AppearancePreviewPalette {
    let canvas: Color
    let panel: Color
    let line: Color
    let strongLine: Color
    let divider: Color

    static let light = AppearancePreviewPalette(
        canvas: Color(white: 0.92),
        panel: Color(white: 0.99),
        line: Color.black.opacity(0.08),
        strongLine: Color.black.opacity(0.15),
        divider: Color.black.opacity(0.08)
    )

    static let dark = AppearancePreviewPalette(
        canvas: Color(white: 0.25),
        panel: Color(white: 0.13),
        line: Color.white.opacity(0.17),
        strongLine: Color.white.opacity(0.30),
        divider: Color.white.opacity(0.10)
    )
}
