import AppKit
import SwiftUI

struct SignInView: View {
    private var auth = SupabaseService.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var notice: String?
    @State private var mode: Mode = .signIn

    private enum Mode { case signIn, signUp, confirmInbox }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            VStack(spacing: AppTheme.Spacing.xs) {
                Text("Kawenreel")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .bold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            if mode == .confirmInbox {
                confirmInboxContent
            } else {
                credentialsContent
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private var subtitle: String {
        switch mode {
        case .signIn: "Sign in to continue"
        case .signUp: "Create your account"
        case .confirmInbox: "Confirm your email"
        }
    }

    @ViewBuilder
    private var credentialsContent: some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            field("Email", text: $email, secure: false)
            field("Password", text: $password, secure: true)
        }

        if mode == .signIn {
            Button("Forgot password?") { sendReset() }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .disabled(isWorking || email.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }

        statusText

        Button(action: submit) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if isWorking { ProgressView().controlSize(.small) }
                Text(mode == .signIn ? "Sign In" : "Create Account")
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.Accent.primary)
        .disabled(isWorking || email.isEmpty || password.isEmpty)

        Button(mode == .signIn ? "Need an account? Sign up" : "Have an account? Sign in") {
            error = nil
            notice = nil
            mode = mode == .signIn ? .signUp : .signIn
        }
        .buttonStyle(.plain)
        .font(.system(size: AppTheme.FontSize.sm))
        .foregroundStyle(AppTheme.Accent.primary)
    }

    @ViewBuilder
    private var confirmInboxContent: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "envelope.badge")
                .font(.system(size: AppTheme.FontSize.title2))
                .foregroundStyle(AppTheme.Accent.primary)
            Text("We sent a confirmation link to \(email). Open it, then sign in.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }

        statusText

        Button(action: resend) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if isWorking { ProgressView().controlSize(.small) }
                Text("Resend Email").frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.Accent.primary)
        .disabled(isWorking)

        Button("Back to sign in") {
            error = nil
            notice = nil
            mode = .signIn
        }
        .buttonStyle(.plain)
        .font(.system(size: AppTheme.FontSize.sm))
        .foregroundStyle(AppTheme.Accent.primary)
    }

    @ViewBuilder
    private var statusText: some View {
        if let error {
            Text(error)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        } else if let notice {
            Text(notice)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text).onSubmit(submit)
            } else {
                TextField(placeholder, text: text)
                    .textContentType(.username)
                    .onSubmit(submit)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: AppTheme.FontSize.md))
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black.opacity(AppTheme.Opacity.muted)))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin))
    }

    private func submit() {
        guard !isWorking, !email.isEmpty, !password.isEmpty else { return }
        isWorking = true
        error = nil
        notice = nil
        Task {
            do {
                if mode == .signIn {
                    try await auth.signIn(email: email, password: password)
                } else {
                    let sessionCreated = try await auth.signUp(email: email, password: password)
                    if !sessionCreated { mode = .confirmInbox }
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func resend() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await auth.resendConfirmation(email: email)
                notice = "Confirmation email sent."
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func sendReset() {
        guard !isWorking, !email.isEmpty else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await auth.sendPasswordReset(email: email)
                notice = "Password reset link sent to \(email)."
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

final class SignInWindowController: NSWindowController {
    static let shared = SignInWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SignInView().tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign In"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Restores the auth session at launch and dismisses the sign-in window once a
/// session exists. Sign-in is optional — it unlocks the server-side LLM proxy —
/// so there is no gate: the app stays fully reachable while signed out.
@MainActor
enum AuthCoordinator {
    static func start() {
        SupabaseService.shared.onAuthChange = route(signedIn:)
        SupabaseService.shared.start()
    }

    private static func route(signedIn: Bool) {
        if signedIn {
            SignInWindowController.shared.close()
        }
    }
}
