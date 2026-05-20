import SwiftUI

struct AIAccessGate: ViewModifier {
    @Bindable private var account = AccountService.shared

    fileprivate enum GateState {
        case allowed
        case misconfigured
        case signInRequired
        case subscribeRequired
    }

    private var state: GateState {
        if account.isMisconfigured { return .misconfigured }
        if !account.isSignedIn { return .signInRequired }
        if !account.isPaid { return .subscribeRequired }
        return .allowed
    }

    func body(content: Content) -> some View {
        let gateState = state
        ZStack {
            content
                .disabled(gateState != .allowed)
                .blur(radius: gateState == .allowed ? 0 : 6)
            if gateState != .allowed {
                overlayCard(for: gateState)
            }
        }
    }

    private func overlayCard(for gateState: GateState) -> some View {
        VStack(spacing: 0) {
            Text(gateState.title)
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(gateState.subtitle)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppTheme.Spacing.xs)
            ctaButton(for: gateState)
                .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .padding(AppTheme.Spacing.md)
    }

    @ViewBuilder
    private func ctaButton(for gateState: GateState) -> some View {
        switch gateState {
        case .signInRequired:
            Button {
                Task { await account.signInWithGoogle() }
            } label: {
                Text("Sign in with Google").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .subscribeRequired:
            Button {
                Task { await account.subscribe(tier: .pro) }
            } label: {
                Text("Subscribe").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .misconfigured, .allowed:
            EmptyView()
        }
    }
}

private extension AIAccessGate.GateState {
    var title: String {
        switch self {
        case .misconfigured: "AI unavailable"
        case .signInRequired: "Sign in to use AI"
        case .subscribeRequired: "Subscribe to use AI"
        case .allowed: ""
        }
    }

    var subtitle: String {
        switch self {
        case .misconfigured:
            "This build was compiled without Palmier backend access."
        case .signInRequired:
            "Generate video, images, and audio with your Palmier account."
        case .subscribeRequired:
            "Unlock video, image, and audio generation on Pro or Max."
        case .allowed:
            ""
        }
    }
}

extension View {
    func aiAccessGate() -> some View { modifier(AIAccessGate()) }
}
