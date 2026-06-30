import AppKit
import SwiftUI

struct ToolbarView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var showMatteSheet = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Undo / Redo
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: undo)
                toolbarButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: redo)
            }

            Divider()
                .frame(height: AppTheme.Spacing.xl)

            // Tool mode
            HStack(spacing: AppTheme.Spacing.md) {
                toolModeButton("cursorarrow", mode: .pointer, help: "Pointer (V)")
                toolModeButton("scissors", mode: .razor, help: "Razor (C)")
            }

            Divider()
                .frame(height: AppTheme.Spacing.xl)

            // Split, trim buttons
            HStack(spacing: AppTheme.Spacing.md) {
                toolbarButton("square.split.2x1", help: "Split at Playhead (⌘K)", action: editor.splitAtPlayhead)
                bracketButton("[", help: "Trim Start to Playhead (Q)", action: editor.trimStartToPlayhead)
                bracketButton("]", help: "Trim End to Playhead (W)", action: editor.trimEndToPlayhead)
            }

            Divider()
                .frame(height: AppTheme.Spacing.xl)

            // Add content
            HStack(spacing: AppTheme.Spacing.md) {
                textGlyphButton("T", help: "Add Text", action: { _ = editor.addTextClip() })
                matteButton
            }

            Spacer()

            // Zoom
            HStack(spacing: AppTheme.Spacing.xs) {
                zoomButton(
                    "minus.magnifyingglass",
                    help: "Zoom Out",
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
                    help: "Zoom In",
                    isDisabled: editor.zoomScale >= Zoom.max,
                    action: zoomIn
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var matteButton: some View {
        Button { showMatteSheet = true } label: {
            Image(systemName: "square.fill")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Create Matte")
        .sheet(isPresented: $showMatteSheet) {
            MatteSheet(isPresented: $showMatteSheet)
        }
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
        .help(help)
    }

    private func zoomButton(
        _ systemName: String,
        help: String,
        isDisabled: Bool,
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
        .help(help)
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
        .help(help)
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
        .help(help)
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
        .help(help)
    }
}

private struct MatteSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var isPresented: Bool
    @State private var color = Color.black
    @State private var aspect = MatteAspect.project
    @State private var isCreating = false
    @State private var error: String?

    private var dims: (width: Int, height: Int) {
        aspect.pixelSize(timelineWidth: editor.timeline.width, timelineHeight: editor.timeline.height)
    }

    private let controlWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            row(icon: "paintpalette", label: "Color") {
                ColorField(displayColor: color, onUserChange: { color = $0 }, supportsOpacity: false)
            }
            row(icon: "aspectratio", label: "Aspect") {
                Picker("", selection: $aspect) {
                    ForEach(MatteAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            row(icon: "ruler", label: "Size") {
                Text("\(dims.width) × \(dims.height)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .monospacedDigit()
            }
            if let error {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            Button(action: create) {
                Text(isCreating ? "Creating…" : "Create Matte")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Background.baseColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
            .padding(.top, AppTheme.Spacing.xs)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(width: 280)
    }

    private func row<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm)
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.md)
            control()
                .frame(width: controlWidth, alignment: .trailing)
        }
    }

    private func create() {
        error = nil
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                _ = try await editor.createMatte(hex: color.matteHex, aspect: aspect, folderId: editor.mediaPanelCurrentFolderId)
                isPresented = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
