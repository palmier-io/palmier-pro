import AppKit
import SwiftUI

/// Persistent problems (missing media, unreadable plans, unreachable package) that stay on screen
/// until fixed, unlike a toast that disappears before the user can act.
struct RecoveryBannerView: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var notices: [RecoveryNotice] = []
    @State private var dismissed: Set<RecoveryNotice.Kind> = []

    private var visible: [RecoveryNotice] {
        notices.filter { !dismissed.contains($0.kind) }
    }

    var body: some View {
        if !visible.isEmpty {
            VStack(spacing: 0) {
                ForEach(visible) { notice in
                    row(notice)
                }
            }
            .background(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.hint))
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
            .task(id: editor.missingMediaRefs.count) { await refresh() }
        }
    }

    private func row(_ notice: RecoveryNotice) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.warningColor)
            Text(verbatim: notice.message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(2)
            Spacer(minLength: AppTheme.Spacing.sm)
            if notice.kind == .missingMedia {
                Button(L10n.string("Relink…")) { relinkFolder() }
                    .buttonStyle(.capsule(.secondary))
                    .fixedSize()
            }
            Button {
                dismissed.insert(notice.kind)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Dismiss"))
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @MainActor
    private func refresh() async {
        let folderMissing = await RecoveryNoticeBuilder.folderMissing(editor.projectURL)
        notices = RecoveryNoticeBuilder.notices(
            missingMediaCount: editor.missingMediaRefs.count,
            plansUnreadable: editor.editPlansLoadFailed,
            projectFolderMissing: folderMissing,
            localize: { L10n.string(key: $0) }
        )
        dismissed = dismissed.intersection(Set(notices.map(\.kind)))
    }

    private func relinkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose the folder that holds your media")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { [editor] in
                await editor.relinkOfflineAssets(fromFolder: url)
            }
        }
    }
}
