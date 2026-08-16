import AppKit
import SwiftUI

struct OnboardingWelcomeStep: View {
    private static let hero = BundledResource.url("Images/welcome-butterfly.jpg")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            OnboardingTitle(L10n.string("Welcome to Palmier Pro"))
            heroImage
            OnboardingDetail(L10n.string("A video editor built for AI. Generate, and edit all in one place."))
        }
    }

    private var heroImage: some View {
        Group {
            if let hero = Self.hero {
                Image(nsImage: hero).resizable().aspectRatio(contentMode: .fill)
            } else {
                AppTheme.Background.raisedColor
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.Onboarding.welcomeHeroHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
    }
}

struct OnboardingQuestionnaireStep: View {
    @Bindable var onboarding: OnboardingStore
    let title: String
    let questions: [OnboardingQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            OnboardingTitle(title)
            ForEach(questions) { question in
                Spacer(minLength: AppTheme.Spacing.md)
                section(question)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ question: OnboardingQuestion) -> some View {
        let selection = onboarding.selection(for: question)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string(key: question.titleKey))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
            OnboardingFlowLayout(spacing: AppTheme.Spacing.smMd) {
                ForEach(question.options) { option in
                    let isSelected = selection.contains(option.id)
                    Button {
                        onboarding.toggle(option, for: question)
                    } label: {
                        Text(L10n.string(key: option.labelKey))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
                            .lineLimit(1)
                    }
                    .buttonStyle(.capsule(
                        isSelected ? .prominent : .secondary,
                        size: .small,
                        fill: isSelected ? nil : AnyShapeStyle(AppTheme.Onboarding.secondaryButtonFill)
                    ))
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct OnboardingFlowLayout: SwiftUI.Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, arrangement(width: bounds.width, subviews: subviews).frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: LayoutSubviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize.unspecified)
            let nextX = cursor.x == 0 ? 0 : cursor.x + spacing
            if nextX + size.width > width, cursor.x > 0 {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            } else {
                cursor.x = nextX
            }
            frames.append(CGRect(origin: cursor, size: size))
            cursor.x += size.width
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, cursor.x)
        }

        return (CGSize(width: contentWidth, height: cursor.y + rowHeight), frames)
    }
}

struct OnboardingAccountStep: View {
    @Bindable var account: AccountService
    let sampleState: OnboardingSampleState
    let signInFailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                OnboardingTitle(title)
                OnboardingDetail(detail)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var title: String {
        guard account.isSignedIn else {
            return L10n.string("Sign In")
        }
        guard let firstName = account.account?.user.firstName else {
            return L10n.string("Welcome")
        }
        return L10n.string("Welcome, \(firstName)")
    }

    private var detail: String {
        account.isSignedIn
            ? L10n.string("Watch the tutorial or start creating.")
            : L10n.string("Sign in to receive 250 free credits for AI chat and generation.")
    }

    private var failure: String? {
        if sampleState == .failed {
            return L10n.string("Sample project couldn’t be opened. Try again.")
        }
        if signInFailed, !account.isSignedIn {
            return L10n.string("Sign-in couldn’t be completed. Try again.")
        }
        return nil
    }
}

private struct OnboardingTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
    }
}

private struct OnboardingDetail: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}
