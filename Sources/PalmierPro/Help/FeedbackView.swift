import AppKit
import SwiftUI

struct FeedbackView: View {
    @Bindable private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""
    @State private var email: String = ""
    @State private var includeScreenshot: Bool = true
    @State private var mayContact: Bool = true
    @State private var isSending = false
    @State private var errorText: String?
    @State private var didSend = false

    let screenshot: Data?

    private static let maxMessageLen = 10_000

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasReplyEmail: Bool {
        if account.isSignedIn { return account.account?.user.email != nil }
        return !trimmedEmail.isEmpty
    }

    private var canSubmit: Bool {
        !isSending
            && !trimmedMessage.isEmpty
            && message.count <= Self.maxMessageLen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            if didSend {
                successBlock
            } else {
                formBlock
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.vertical, AppTheme.Spacing.xlXxl)
        .frame(minWidth: 480, idealWidth: 480, minHeight: 420, idealHeight: 480)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
    }

    // MARK: - Form

    private var formBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            descriptionField

            if !account.isSignedIn {
                emailField
            }

            mayContactRow

            if screenshot != nil {
                screenshotRow
            }

            contextNote

            if let errorText {
                Text(errorText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(.red)
            }

            footer
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            fieldLabel("Describe the issue or feedback")
            TextEditor(text: $message)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .frame(height: 160)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.surfaceColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        }
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            fieldLabel("Email (optional)")
            TextField("", text: $email, prompt: Text("you@example.com — so we can reply"))
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.surfaceColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        }
    }

    private var mayContactRow: some View {
        Toggle(isOn: $mayContact) {
            Text("We may email you for follow-up questions")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(hasReplyEmail ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
        }
        .toggleStyle(.checkbox)
        .disabled(!hasReplyEmail)
        .help(hasReplyEmail ? "" : "Add an email above to enable a reply")
    }

    private var screenshotRow: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
            Toggle(isOn: $includeScreenshot) {
                Text("Include screenshot")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            if let screenshot, let thumbnail = NSImage(data: screenshot) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm)
                            .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
                    .opacity(includeScreenshot ? 1.0 : AppTheme.Opacity.medium)
            }
        }
    }

    private var contextNote: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(contextNoteText)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextNoteText: String {
        if account.isSignedIn {
            return "App version \(Self.appVersion) and macOS \(Self.osVersion) are included."
        } else {
            return "App version \(Self.appVersion) and macOS \(Self.osVersion) are included."
        }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSending)
                .keyboardShortcut(.cancelAction)
            Button(action: submit) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AppTheme.Text.primaryColor)
                    }
                    Text(isSending ? "Sending…" : "Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    // MARK: - Success

    private var successBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Accent.primary)
                Text("Thanks for the feedback.")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            Text(successDetailText)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var successDetailText: String {
        let replyAddr = account.account?.user.email
            ?? (trimmedEmail.isEmpty ? nil : trimmedEmail)
        if let replyAddr, mayContact {
            return "We read every message and may reach out at \(replyAddr)."
        }
        if replyAddr != nil {
            return "We read every message. We won't email you, as requested."
        }
        return "We read every message. Add an email next time if you'd like a reply."
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private func submit() {
        guard canSubmit else { return }
        errorText = nil
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            do {
                let attachedScreenshot = (includeScreenshot ? screenshot : nil)?.base64EncodedString()
                try await account.sendFeedback(
                    message: trimmedMessage,
                    email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                    mayContact: hasReplyEmail ? mayContact : false,
                    screenshotPngBase64: attachedScreenshot,
                    appVersion: Self.appVersion,
                    osVersion: Self.osVersion
                )
                didSend = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Environment info

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

@MainActor
final class FeedbackWindowController: NSWindowController {
    static let shared = FeedbackWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let initialView = FeedbackView(screenshot: nil).tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 480, height: 480))
        window.minSize = NSSize(width: 480, height: 420)
        window.title = "Send feedback"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.isReleasedWhenClosed = false
        window.center()
        self.hosting = hosting
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // Capture BEFORE the feedback window becomes key so it isn't in the shot.
        let screenshot = FeedbackScreenshot.captureMainWindow()
        hosting?.rootView = AnyView(
            FeedbackView(screenshot: screenshot)
                .id(UUID())
                .tint(AppTheme.Accent.primary)
        )
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    FeedbackView(screenshot: nil)
}
