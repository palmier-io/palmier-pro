import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 36)

            Text("Settings")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, 24)
                .padding(.bottom, AppTheme.Spacing.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    PrivacyPane()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 380, idealHeight: 440)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 580, height: 440))
        window.minSize = NSSize(width: 540, height: 380)
        window.title = "Settings"
        window.setFrameAutosaveName("PalmierProSettings")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
