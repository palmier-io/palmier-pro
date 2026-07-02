import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-launch setup: welcome → what you edit → AI setup → style reference.
/// Every step after the first is skippable; finishing (or skipping through)
/// marks the profile onboarded and opens Home.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0
    @State private var selectedDomain: String?
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var addedReferences: [StyleReferenceStore.GlobalReference] = []
    @Bindable private var modelLoader = VisualModelLoader.shared
    @Bindable private var styleStore = StyleReferenceStore.shared

    private static let stepCount = 4

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(width: 520, height: 480)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: domainStep
        case 2: aiStep
        default: styleStep
        }
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(0..<Self.stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? AppTheme.Accent.primary : Color.white.opacity(AppTheme.Opacity.muted))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step > 0 {
                Button("Skip") { advance() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            }
            Button(step == Self.stepCount - 1 ? "Finish" : "Continue") { advance() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .keyboardShortcut(.defaultAction)
                .disabled(step == 1 && selectedDomain == nil)
        }
    }

    private func advance() {
        if step < Self.stepCount - 1 {
            withAnimation { step += 1 }
        } else {
            UserProfileStore.shared.markOnboarded()
            onFinish()
        }
    }

    // MARK: - Step 1: Welcome

    private static let hero: NSImage? = {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/welcome-butterfly.jpg"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Images/welcome-butterfly.jpg"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { NSImage(contentsOf: $0) }
    }()

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header("Welcome to Kawenreel", "AI-native video editing for wedding filmmakers.")
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
    }

    // MARK: - Step 2: Domain

    private var domainStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header("What do you edit most?", "This tunes the AI's editing knowledge for you.")
            VStack(spacing: AppTheme.Spacing.sm) {
                domainCard("malay_wedding", title: "Malay weddings",
                           subtitle: "Ceremony structure, moments, and grading learned from real wedding films.",
                           icon: "heart")
                domainCard("events", title: "Other events",
                           subtitle: "Corporate, parties, celebrations.",
                           icon: "party.popper")
                domainCard("general", title: "General video",
                           subtitle: "Social content, vlogs, everything else.",
                           icon: "film")
            }
        }
    }

    private func domainCard(_ id: String, title: String, subtitle: String, icon: String) -> some View {
        Button {
            selectedDomain = id
            UserProfileStore.shared.saveEditingDomain(id)
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.lg))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.lg)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(subtitle)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                if selectedDomain == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(selectedDomain == id ? AppTheme.Opacity.faint : AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        selectedDomain == id ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: AI setup

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header("Set up the AI", "Both are optional — change anytime in Settings.")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("On-device footage analysis")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Finds and tags your footage automatically. Runs on your Mac — nothing is uploaded.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                modelRow
            }

            Divider().overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("AI chat")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if AccountService.shared.aiAllowed {
                    Text("Your account includes hosted AI — nothing to configure.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else {
                    Text("Paste an Anthropic API key so the AI can edit with you. Stored in your macOS Keychain.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button(keySaved ? "Saved" : "Save") {
                            AnthropicKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            keySaved = true
                        }
                        .disabled(apiKey.isEmpty || keySaved)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch modelLoader.state {
        case .notInstalled, .unknown, .failed:
            Button("Download in background") { modelLoader.download() }
                .controlSize(.small)
        case .downloading(let fraction):
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView(value: fraction).frame(width: 160)
                Text("Downloading — you can continue")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .preparing, .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    // MARK: - Step 4: Style reference

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header("Teach it your style",
                   "Drop a film you've edited before. The AI learns your color, pacing, and structure — and follows them in every project.")

            dropzone

            if !addedReferences.isEmpty {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(addedReferences) { ref in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: "film")
                                .foregroundStyle(AppTheme.Accent.primary)
                            Text(ref.name)
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .lineLimit(1)
                            Spacer()
                            if styleStore.states[ref.id] == .analyzing || styleStore.states[ref.id] == .pending {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.Accent.primary)
                            }
                        }
                        .padding(AppTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(Color.white.opacity(AppTheme.Opacity.faint))
                        )
                    }
                }
            }
        }
    }

    private var dropzone: some View {
        Button(action: chooseReference) {
            VStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: AppTheme.FontSize.title2))
                    .foregroundStyle(AppTheme.Accent.primary)
                Text("Drop a video here or click to choose")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, style: StrokeStyle(
                        lineWidth: AppTheme.BorderWidth.thin, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { return }
                    Task { @MainActor in addReference(url) }
                }
            }
            return true
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { addReference(url) }
        }
    }

    private func addReference(_ url: URL) {
        guard let ref = try? StyleReferenceStore.shared.addGlobal(url: url) else { return }
        addedReferences.append(ref)
    }

    // MARK: - Shared

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(subtitle)
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let hosting = NSHostingController(rootView: OnboardingView(onFinish: {
            OnboardingWindowController.shared.close()
            HomeWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }).tint(AppTheme.Accent.primary))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome"
        window.styleMask = [.titled, .fullSizeContentView]
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
