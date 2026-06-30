import AppKit
import SwiftUI

struct TourOverlay: View {
    @Environment(EditorViewModel.self) private var editor

    private var tour: TourController { editor.tour }
    private let cardWidth: CGFloat = 320
    private let bookendWidth: CGFloat = 600
    private let margin: CGFloat = AppTheme.Spacing.xlXxl

    private static let docsURL = URL(string: "https://palmier.io/docs")!

    var body: some View {
        if let step = tour.currentStep {
            GeometryReader { geo in
                let frame = tour.targetFrame
                let isSpotlight = isSpotlightStep(step)
                ZStack(alignment: .topLeading) {
                    scrim(cutout: isSpotlight ? frame : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { if isSpotlight { tour.end() } }

                    switch step.kind {
                    case .intro:
                        introCard(step)
                            .frame(width: bookendWidth)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    case .outro:
                        outroCard(step)
                            .frame(width: bookendWidth)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    case .spotlight:
                        if let frame {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                .strokeBorder(AppTheme.Accent.spotlightGradient, lineWidth: AppTheme.BorderWidth.thick)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                                .shadow(color: AppTheme.Accent.spotlight.opacity(AppTheme.Opacity.strong), radius: 10)
                                .allowsHitTesting(false)
                        }
                        callout(step)
                            .frame(width: cardWidth)
                            .position(calloutPosition(for: frame, in: geo.size))
                    }
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    private func isSpotlightStep(_ step: TourStep) -> Bool {
        if case .spotlight = step.kind { return true }
        return false
    }

    private func scrim(cutout: CGRect?) -> some View {
        Color.black.opacity(AppTheme.Opacity.strong)
            .reverseMask {
                if let cutout {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .frame(width: cutout.width, height: cutout.height)
                        .offset(x: cutout.minX, y: cutout.minY)
                }
            }
    }

    // MARK: - Spotlight callout

    private func callout(_ step: TourStep) -> some View {
        let index = tour.stepIndex ?? 0
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Step \(index) of \(tour.spotlightCount)")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(step.title)
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(step.instruction)
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Skip") { tour.end() }
                    .buttonStyle(.capsule)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back") { tour.back() }
                    .buttonStyle(.capsule)
                Button("Next") { tour.advance() }
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppTheme.Spacing.xs)
        }
        .padding(AppTheme.Spacing.lg)
        .tourCardBackground()
    }

    // MARK: - Intro / outro cards

    private func introCard(_ step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(step.title)
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(step.instruction)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            heroImage
            HStack {
                Button("Skip") { tour.end() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Next") { tour.advance() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xxl)
        .tourGlassBackground()
    }

    @ViewBuilder
    private var heroImage: some View {
        Group {
            if let hero = TourAssets.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.aiGradient
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }

    private func outroCard(_ step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(step.title)
                    .font(.system(size: AppTheme.FontSize.title1, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(step.instruction)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                linkRow("Skills", "book.closed.fill") { SettingsWindowController.shared.show(tab: .skills) }
                linkRow("MCP Setup", "puzzlepiece.extension.fill") { HelpWindowController.shared.show(tab: .mcp) }
                linkRow("Keyboard Shortcuts", "keyboard") { HelpWindowController.shared.show(tab: .shortcuts) }
                linkRow("Documentation", "book.fill") { NSWorkspace.shared.open(Self.docsURL, configuration: .init(), completionHandler: nil) }
                linkRow("Settings", "gearshape.fill") { SettingsWindowController.shared.show() }
            }
            HStack {
                Spacer()
                Button("Start creating") { tour.end() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xxl)
        .tourGlassBackground()
    }

    private func linkRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.sm)
                Text(title)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .padding(.vertical, AppTheme.Spacing.smMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Place the spotlight card adjacent to the highlighted region
    private func calloutPosition(for frame: CGRect?, in size: CGSize) -> CGPoint {
        guard let frame else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let neededX = cardWidth + margin * 2
        let cardHalf = estimatedCardHeight / 2

        if size.width - frame.maxX > neededX {            // room to the right
            return CGPoint(x: frame.maxX + margin + cardWidth / 2, y: clampY(frame.midY, in: size))
        }
        if frame.minX > neededX {                         // room to the left
            return CGPoint(x: frame.minX - margin - cardWidth / 2, y: clampY(frame.midY, in: size))
        }
        let x = clampX(frame.midX, in: size)
        if frame.minY > estimatedCardHeight + margin * 2 { // room above (sit just above the frame)
            return CGPoint(x: x, y: clampY(frame.minY - margin - cardHalf, in: size))
        }
        return CGPoint(x: x, y: clampY(frame.maxY + margin + cardHalf, in: size)) // else below
    }

    /// Generous height estimate so the card's full extent stays on-screen after clamping.
    private var estimatedCardHeight: CGFloat { 220 }

    private func clampX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        min(max(x, cardWidth / 2 + margin), size.width - cardWidth / 2 - margin)
    }

    private func clampY(_ y: CGFloat, in size: CGSize) -> CGFloat {
        let half = estimatedCardHeight / 2
        return min(max(y, half + margin), size.height - half - margin)
    }
}

// MARK: - Anchor tagging

extension View {
    /// Registers this view's backing `NSView` as a tour anchor, so the split
    /// controller can highlight it. Pair with a `TourStep` targeting `.element(id)`.
    func tourAnchor(_ id: TourAnchorID) -> some View {
        background(TourAnchorRegistrar(id: id))
    }
}

private struct TourAnchorRegistrar: NSViewRepresentable {
    let id: TourAnchorID
    @Environment(EditorViewModel.self) private var editor

    func makeNSView(context: Context) -> TourAnchorNSView {
        let view = TourAnchorNSView()
        // Recompute the highlight when this control appears/animates inside a panel.
        view.onLayout = { [weak editor] in
            guard let editor else { return }
            DispatchQueue.main.async { editor.tour.anchorDidLayout() }
        }
        editor.tour.anchorViews[id] = WeakView(view)
        return view
    }

    func updateNSView(_ nsView: TourAnchorNSView, context: Context) {
        if editor.tour.anchorViews[id]?.value !== nsView {
            editor.tour.anchorViews[id] = WeakView(nsView)
        }
    }
}

/// Invisible background view that reports when it lays out, so anchors that appear
/// or resize inside a panel trigger a fresh highlight-frame computation.
private final class TourAnchorNSView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Loads bundled tour images from the main bundle
private enum TourAssets {
    static let hero: NSImage? = load("tour-hero", ext: "jpg")

    private static func load(_ name: String, ext: String) -> NSImage? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let candidates = [
            root.appendingPathComponent("Images/\(name).\(ext)"),
            root.appendingPathComponent("PalmierPro_PalmierPro.bundle/Images/\(name).\(ext)"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private extension View {
    func tourCardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(AppTheme.Background.surfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    /// Glassy translucent panel
    func tourGlassBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    /// Punches the masked shapes out of `self` (inverse of `.mask`).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) { mask().blendMode(.destinationOut) }
        }
        .compositingGroup()
    }
}
