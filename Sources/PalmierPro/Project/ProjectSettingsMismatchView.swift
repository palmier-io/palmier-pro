import SwiftUI

struct ProjectSettingsMismatchView: View {
    @Environment(EditorViewModel.self) var editor
    let mismatch: EditorViewModel.SettingsMismatch

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text("Clip Settings Mismatch")
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("The clip you're adding has different settings than the current project.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: AppTheme.Spacing.xl, verticalSpacing: AppTheme.Spacing.sm) {
                GridRow {
                    Text("")
                    Text("Project")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("Clip")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                GridRow {
                    Text("FPS")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(editor.timeline.fps)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("\(mismatch.clipFPS)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(mismatch.clipFPS != editor.timeline.fps ? .orange : AppTheme.Text.primaryColor)
                }
                GridRow {
                    Text("Resolution")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text("\(editor.timeline.width) x \(editor.timeline.height)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("\(mismatch.clipWidth) x \(mismatch.clipHeight)")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(resolutionMismatch ? .orange : AppTheme.Text.primaryColor)
                }
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Button("Keep Current") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("Change to Match") {
                    editor.applyTimelineSettings(
                        fps: mismatch.clipFPS,
                        width: mismatch.clipWidth,
                        height: mismatch.clipHeight
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(AppTheme.Spacing.xl + AppTheme.Spacing.md)
        .frame(width: 360)
    }

    private func dismiss() {
        editor.pendingSettingsContinuation?()
        editor.pendingSettingsContinuation = nil
        editor.pendingSettingsMismatch = nil
    }

    private var resolutionMismatch: Bool {
        mismatch.clipWidth != editor.timeline.width || mismatch.clipHeight != editor.timeline.height
    }
}
