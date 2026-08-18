import AppKit
import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            timelineTabsButton

            toolbarDivider

            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", help: L10n.string("Undo (⌘Z)"), action: undo)
                toolbarButton("arrow.uturn.forward", help: L10n.string("Redo (⇧⌘Z)"), action: redo)
            }

            toolbarDivider

            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer, help: L10n.string("Pointer (V)"))
                toolModeButton("scissors", mode: .razor, help: L10n.string("Razor (C)"))
                toolModeButton("arrow.left.and.right", mode: .trim, help: L10n.string("Trim (T)"))
            }

            toolbarDivider

            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("square.split.2x1", help: L10n.string("Split at Playhead (⌘K)"), action: editor.splitAtPlayhead)
                bracketButton("[", help: L10n.string("Trim Start to Playhead (Q)"), action: editor.trimStartToPlayhead)
                bracketButton("]", help: L10n.string("Trim End to Playhead (W)"), action: editor.trimEndToPlayhead)
            }

            toolbarDivider

            HStack(spacing: AppTheme.Spacing.md) {
                textGlyphButton("T", help: L10n.string("Add Text"), action: { _ = editor.addTextClip() })
                markerButton
            }

            Spacer()

            // Zoom
            HStack(spacing: AppTheme.Spacing.xs) {
                zoomButton(
                    "minus.magnifyingglass",
                    help: L10n.string("Zoom Out"),
                    isDisabled: editor.zoomScale <= editor.minZoomScale,
                    action: zoomOut
                )
                // Log-mapped so slider travel is uniform per zoom factor
                let zoomBinding = Binding(
                    get: { log(editor.zoomScale) },
                    set: { editor.zoomScale = exp($0) }
                )
                Slider(value: zoomBinding, in: log(editor.minZoomScale)...log(Zoom.max))
                    .controlSize(.mini)
                    .tint(AppTheme.Accent.primary)
                    .frame(width: 100)
                zoomButton(
                    "plus.magnifyingglass",
                    help: L10n.string("Zoom In"),
                    isDisabled: editor.zoomScale >= Zoom.max,
                    tooltipAlignment: .bottomTrailing,
                    action: zoomIn
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity)
    }

    private var timelineTabsButton: some View {
        let expanded = editor.isTimelineTabBarExpanded
        return Button {
            editor.toggleTimelineTabBarExpanded()
        } label: {
            Image(systemName: expanded ? "film.stack.fill" : "film.stack")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(expanded ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight(isActive: expanded)
        }
        .buttonStyle(.plain)
        .hoverTooltip(
            L10n.string(expanded ? "Hide Timeline Tabs" : "Show Timeline Tabs"),
            alignment: .bottomLeading
        )
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.primaryColor)
            .frame(width: AppTheme.BorderWidth.thin, height: AppTheme.Spacing.xl)
    }

    private var markerButton: some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Button { _ = editor.addTimelineMarkerAtSelection() } label: {
                TimelineMarkerShape()
                    .fill(AppTheme.Text.secondaryColor)
                    .frame(
                        width: AppTheme.TimelineMarker.flagWidth,
                        height: AppTheme.TimelineMarker.flagHeight
                    )
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.mdLg)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Add Marker (M)"))

            Menu {
                Toggle(
                    L10n.string("Ripple Timeline Markers"),
                    isOn: Bindable(editor).rippleTimelineMarkers
                )
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.Spacing.md, height: AppTheme.IconSize.mdLg)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.string("Ripple Timeline Markers"))
        }
        .padding(.trailing, AppTheme.Spacing.xxs)
        .hoverHighlight()
        .hoverTooltip(L10n.string("Add Marker (M)"))
    }

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .hoverTooltip(help)
    }

    private func zoomButton(
        _ systemName: String,
        help: String,
        isDisabled: Bool,
        tooltipAlignment: Alignment = .bottom,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isDisabled ? AppTheme.Text.mutedColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .hoverTooltip(help, alignment: tooltipAlignment)
    }

    private func zoomOut() {
        setZoomScale(editor.zoomScale / Zoom.toolbarStepFactor)
    }

    private func zoomIn() {
        setZoomScale(editor.zoomScale * Zoom.toolbarStepFactor)
    }

    private func setZoomScale(_ zoomScale: Double) {
        editor.zoomScale = min(Zoom.max, max(editor.minZoomScale, zoomScale))
    }

    private func undo() {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    private func redo() {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    private func toolModeButton(_ systemName: String, mode: ToolMode, help: String) -> some View {
        let isActive = editor.toolMode == mode
        return Button { editor.toolMode = mode } label: {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
        .hoverTooltip(help)
    }

    private func textGlyphButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .hoverTooltip(help)
    }

    private func bracketButton(_ bracket: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(bracket)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .hoverTooltip(help)
    }
}
