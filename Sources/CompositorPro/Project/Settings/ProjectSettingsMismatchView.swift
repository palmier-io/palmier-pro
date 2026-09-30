import SwiftUI

struct ProjectSettingsMismatchView: View {
    @Environment(EditorViewModel.self) var editor
    let mismatch: EditorViewModel.SettingsMismatch

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text(L10n.string("Clip Settings Mismatch"))
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text(L10n.string("The clip you're adding has different settings than the current project."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.xl, verticalSpacing: AppTheme.Spacing.sm) {
                GridRow {
                    Text(verbatim: "")
                    Text(L10n.string("Project"))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(L10n.string("Clip"))
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                GridRow {
                    Text(verbatim: "FPS")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(verbatim: "\(editor.timeline.fps)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(verbatim: "\(mismatch.clipFPS)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(mismatch.clipFPS != editor.timeline.fps ? .orange : AppTheme.Text.primaryColor)
                }
                GridRow {
                    Text(L10n.string("Resolution"))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(verbatim: "\(editor.timeline.width) x \(editor.timeline.height)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(verbatim: "\(mismatch.clipWidth) x \(mismatch.clipHeight)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(resolutionMismatch ? .orange : AppTheme.Text.primaryColor)
                }
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Button(L10n.string("Keep Current")) {
                    dismiss()
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.regular)

                Button(L10n.string("Change to Match")) {
                    editor.applyTimelineSettings(
                        fps: mismatch.clipFPS,
                        width: mismatch.clipWidth,
                        height: mismatch.clipHeight
                    )
                    dismiss()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.regular)
            }
        }
        .padding(AppTheme.Spacing.xl + AppTheme.Spacing.md)
        .frame(width: 360)
        .appSheetBackground()
    }

    private func dismiss() {
        let continuation = editor.pendingSettingsContinuation
        (editor.pendingSettingsContinuation, editor.pendingSettingsMismatch) = (nil, nil)
        continuation?()
    }

    private var resolutionMismatch: Bool {
        mismatch.clipWidth != editor.timeline.width || mismatch.clipHeight != editor.timeline.height
    }
}
