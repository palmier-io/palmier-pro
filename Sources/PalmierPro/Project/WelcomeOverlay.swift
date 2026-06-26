import AppKit
import SwiftUI

/// First-launch welcome shown over the Home screen
struct WelcomeOverlay: View {
    let onDismiss: () -> Void

    @Bindable private var account = AccountService.shared
    @State private var startingTutorial = false
    private static let hero: NSImage? = loadHero()

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 520)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Welcome to Palmier Pro")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("A video editor built for AI. Generate, and edit all in one place.")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            heroImage
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Skip") { onDismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { startTutorial() } label: {
                    if startingTutorial {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Text("Watch Tutorial")
                    }
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .disabled(startingTutorial)
                signInButton
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    @ViewBuilder
    private var signInButton: some View {
        if account.aiAllowed || account.isMisconfigured {
            Button("Get started") { onDismiss() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
        } else {
            Button(account.isSigningIn ? "Opening Google…" : "Sign In") {
                Task { await account.signInWithGoogle() }
            }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(account.isSigningIn)
        }
    }

    /// Open the first sample (downloading if needed); it auto-starts the tutorial.
    private func startTutorial() {
        startingTutorial = true
        Task {
            defer { startingTutorial = false }
            guard let sample = try? await SampleProjectService.shared.fetchSamples().first else {
                onDismiss()   // nothing to open
                return
            }
            do {
                try await AppState.shared.openSample(slug: sample.slug, startTutorial: true)
                onDismiss()
            } catch {
                // Leave the welcome up so the user can retry or skip.
            }
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private static func loadHero() -> NSImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/welcome-butterfly.jpg"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Images/welcome-butterfly.jpg"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
