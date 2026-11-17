import AppKit
import SwiftUI

struct MCPConnectionCodeBlock: View {
    let content: String
    var fontSize = AppTheme.FontSize.xs
    var foreground = AppTheme.Text.secondaryColor
    var verticalPadding = AppTheme.Spacing.md

    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                Text(verbatim: content)
                    .font(.system(size: fontSize, weight: AppTheme.FontWeight.regular, design: .monospaced))
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(copied ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Copy"))
                .help(copied ? L10n.string("Copied") : L10n.string("Copy"))
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, verticalPadding)
            .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)

            if copyFailed {
                Text(L10n.string("Could not copy. Select the text and copy it manually."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        .onChange(of: content) { _, _ in
            copied = false
            copyFailed = false
        }
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: AppTheme.Workspace.copyFeedbackDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(content, forType: .string)
        copyFailed = !copied
    }
}
