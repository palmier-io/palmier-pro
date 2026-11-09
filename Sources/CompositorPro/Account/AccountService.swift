import AppKit
import Foundation

/// Local-only account facade after the backend teardown (R1).
///
/// The hosted Palmier account (Clerk sign-in, Convex subscriptions, credits)
/// is gone: this type keeps the capability/consumption surface consumers use,
/// always signed out with no credits, so nothing in the app can mistake a
/// local-only build for a signed-in product.
enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }

    var planLabel: String {
        switch self {
        case .none: return L10n.key("Free")
        case .pro: return L10n.key("Pro plan")
        case .max: return L10n.key("Max plan")
        }
    }

    var upgradeLabel: String {
        switch self {
        case .none: return ""
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }
}

struct AccountUser: Decodable, Sendable {
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? {
        displayName?.split(separator: " ").first.map(String.init)
    }
}

struct AccountPlan: Decodable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int {
        hasDiscount ? discountedMonthlyPriceUsd! : monthlyPriceUsd
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceUsd else { return false }
        return discounted < monthlyPriceUsd
    }
}

struct AccountResponse: Decodable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

/// Local-only facade: the hosted identity system is removed (R1). Kept for
/// call-site compatibility; always signed out with no metering.
struct AccountStore: @unchecked Sendable {
    var user: AccountUser?
}

@Observable
@MainActor
final class AccountService: @unchecked Sendable {
    static let shared = AccountService()

    // --- Local-only facade: the hosted identity system is removed (R1). ---
    var account: AccountStore? { nil }
    var user: AccountUser? { nil }
    var isSignedIn: Bool { false }
    var isLoading: Bool { false }
    var isSigningIn: Bool { false }
    var isBuyingCredits: Bool { false }
    var isPaid: Bool { false }
    var aiAllowed: Bool { false }
    var isMisconfigured: Bool { true }
    var hasCredits: Bool { false }
    var remainingCredits: Int { 0 }
    var budgetCredits: Int? { nil }
    var spentCredits: Int? { nil }
    var availablePlans: [AvailablePlan] { [] }
    var lastError: String?

    func configure() {}
    func signInWithGoogle() async {}
    func signOut() async {}
    func subscribe(tier: AccountTier) async {}
    func buyCredits(amount: Int) async {}
    func subscribeToPlan(_ plan: AvailablePlan) async {}
    func sendFeedback(
        message: String,
        email: String? = nil,
        mayContact: Bool = false,
        screenshotPngBase64: String? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil
    ) async throws {}

    // Mirror of the removed Convex-backed API: hosted pipelines cannot run.
    var convex: Any? { nil }
}

enum FeedbackSubtype: String, CaseIterable {
    case bug = "bug report"
    case feature = "feature request"
    case other = "other"
}
