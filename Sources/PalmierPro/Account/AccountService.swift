import AppKit
import Foundation
import Combine
import ClerkKit
import ClerkConvex
@preconcurrency import ConvexMobile

enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }

    var planLabel: String {
        switch self {
        case .none: return "Free"
        case .pro: return "Pro plan"
        case .max: return "Max plan"
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

private struct UrlResponse: Decodable, Sendable {
    let url: String
}

private struct OkResponse: Decodable, Sendable {
    let ok: Bool
}

@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private static let allowedBillingHosts: Set<String> = [
        "checkout.stripe.com",
        "billing.stripe.com",
    ]

    private(set) var isLoading: Bool = true
    private(set) var isMisconfigured: Bool = false
    private(set) var account: AccountResponse?
    private(set) var availablePlans: [AvailablePlan] = []
    private(set) var lastError: String?
    private(set) var isBuyingCredits: Bool = false
    private(set) var authState: AuthState<String> = .loading

    var isSignedIn: Bool {
        guard !isMisconfigured, case .authenticated = authState else { return false }
        return true
    }
    var aiAllowed: Bool { isSignedIn && !isMisconfigured }
    var tier: AccountTier { account?.user.tier ?? .none }
    var isPaid: Bool { tier.isPaid }

    var spentCredits: Int { account?.user.spentCreditsThisPeriod ?? 0 }
    var budgetCredits: Int? {
        guard let user = account?.user else { return nil }
        let tierBudget = account?.plan?.monthlyBudgetCredits ?? 0
        return tierBudget + (user.purchasedCredits ?? 0)
    }

    var remainingCredits: Int { max(0, (budgetCredits ?? 0) - spentCredits) }
    var hasCredits: Bool { remainingCredits > 0 }

    @ObservationIgnored private(set) var convex: ConvexClientWithAuth<String>?
    @ObservationIgnored private var accountSubscription: AnyCancellable?
    @ObservationIgnored private var plansSubscription: AnyCancellable?
    @ObservationIgnored private var authStateTask: Task<Void, Never>?
    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var buyCreditsTask: Task<Void, Never>?

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true

        guard let publishableKey = BackendConfig.clerkPublishableKey,
              let deploymentURL = BackendConfig.convexDeploymentURL
        else {
            isMisconfigured = true
            isLoading = false
            Log.account.warning(
                "account backend misconfigured",
                telemetry: "Account backend misconfigured",
                data: [
                    "hasClerkKey": BackendConfig.clerkPublishableKey != nil,
                    "hasConvexURL": BackendConfig.convexDeploymentURL != nil
                ]
            )
            return
        }

        Clerk.configure(
            publishableKey: publishableKey,
            options: Clerk.Options(
                redirectConfig: .init(
                    redirectUrl: "palmier://callback",
                    callbackUrlScheme: "palmier"
                )
            )
        )
        convex = ConvexClientWithAuth(
            deploymentUrl: deploymentURL.absoluteString,
            authProvider: ClerkConvexAuthProvider()
        )
        Log.account.notice("account configured", telemetry: "Account configured")
        startPlansSubscription()

        startAuthObservation()
    }

    private func startAuthObservation() {
        guard let convex else { return }
        authStateTask = Task { @MainActor [weak self] in
            // Wait for Clerk to restore any cached session first.
            for _ in 0..<50 where !Clerk.shared.isLoaded {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            for await state in convex.authState.values {
                guard let self else { return }
                self.authState = state
                switch state {
                case .loading:
                    Log.account.notice("auth state loading", telemetry: "Auth state changed", data: ["state": "loading"])
                    self.isLoading = true
                case .authenticated:
                    Log.account.notice("auth state authenticated", telemetry: "Auth state changed", data: ["state": "authenticated"])
                    await self.provisionAndSubscribe()
                    self.isLoading = false
                case .unauthenticated:
                    Log.account.notice("auth state unauthenticated", telemetry: "Auth state changed", data: ["state": "unauthenticated"])
                    self.clearAccount()
                    self.isLoading = Clerk.shared.session != nil
                }
            }
        }
    }

    private func provisionAndSubscribe() async {
        guard let convex else { return }

        let user = Clerk.shared.user
        let name = [user?.firstName, user?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        let args: [String: ConvexEncodable?] = [
            "email": user?.primaryEmailAddress?.emailAddress,
            "name": name.isEmpty ? nil : name,
            "image": user?.imageUrl,
        ]

        for attempt in 0..<3 {
            do {
                if attempt == 0 {
                    Log.account.notice("account provision start", telemetry: "Account provision started")
                }
                try await convex.mutation("users:upsertFromAuth", with: args)
                Log.account.notice(
                    "account provision ok attempt=\(attempt + 1)",
                    telemetry: "Account provision finished",
                    data: ["attempt": attempt + 1]
                )
                break
            } catch {
                lastError = error.localizedDescription
                if attempt == 2 {
                    Log.account.warning(
                        "account provision failed error=\(error.localizedDescription)",
                        telemetry: "Account provision failed",
                        data: ["attempt": attempt + 1, "error": error.localizedDescription]
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        startAccountSubscription()
    }

    private func startPlansSubscription() {
        plansSubscription?.cancel()
        plansSubscription = convex?
            .subscribe(to: "billing:listPlans", yielding: [AvailablePlan].self)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        Log.account.warning(
                            "plans subscription failed error=\(err.localizedDescription)",
                            telemetry: "Account plans subscription failed",
                            data: ["error": err.localizedDescription]
                        )
                        self?.lastError = err.localizedDescription
                    }
                },
                receiveValue: { [weak self] plans in
                    self?.availablePlans = plans
                }
            )
    }

    private func startAccountSubscription() {
        accountSubscription?.cancel()
        accountSubscription = convex?
            .subscribe(to: "account:get", yielding: AccountResponse.self)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        Log.account.warning(
                            "account subscription failed error=\(err.localizedDescription)",
                            telemetry: "Account subscription failed",
                            data: ["error": err.localizedDescription]
                        )
                        self?.lastError = err.localizedDescription
                    }
                },
                receiveValue: { [weak self] response in
                    self?.account = response
                    self?.lastError = nil
                }
            )
    }

    private func clearAccount() {
        accountSubscription?.cancel()
        accountSubscription = nil
        buyCreditsTask?.cancel()
        buyCreditsTask = nil
        account = nil
        isBuyingCredits = false
    }

    func signInWithGoogle() async {
        guard !isMisconfigured else { return }
        lastError = nil
        Log.account.notice("sign in requested provider=google", telemetry: "Sign in requested", data: ["provider": "google"])
        do {
            _ = try await Clerk.shared.auth.signInWithOAuth(provider: .google)
        } catch {
            lastError = error.localizedDescription
            Log.account.warning(
                "sign in failed provider=google error=\(error.localizedDescription)",
                telemetry: "Sign in failed",
                data: ["provider": "google", "error": error.localizedDescription]
            )
        }
    }

    func signOut() async {
        guard !isMisconfigured else { return }
        Log.account.notice("sign out requested", telemetry: "Sign out requested")
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            lastError = error.localizedDescription
            Log.account.warning(
                "sign out failed error=\(error.localizedDescription)",
                telemetry: "Sign out failed",
                data: ["error": error.localizedDescription]
            )
        }
    }

    func subscribe(tier: AccountTier) async {
        lastError = nil
        guard tier.isPaid, let convex else { return }
        do {
            let result: UrlResponse = try await convex.action(
                "billing:createCheckoutSession",
                with: ["tier": tier.rawValue]
            )
            openInBrowser(result.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func buyCredits(dollars: Int) {
        guard let convex else { return }
        guard (TopOffLimits.minDollars...TopOffLimits.maxDollars).contains(dollars) else {
            lastError = "Amount must be $\(TopOffLimits.minDollars)–$\(TopOffLimits.maxDollars)."
            return
        }
        if isBuyingCredits { return }
        lastError = nil
        isBuyingCredits = true
        buyCreditsTask = Task { @MainActor [weak self] in
            defer {
                self?.isBuyingCredits = false
                self?.buyCreditsTask = nil
            }
            do {
                let result: UrlResponse = try await convex.action(
                    "billing:createTopOffCheckoutSession",
                    with: ["dollars": Double(dollars)]
                )
                self?.openInBrowser(result.url)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func sendFeedback(
        message: String,
        email: String?,
        mayContact: Bool,
        screenshotPngBase64: String?,
        appVersion: String,
        osVersion: String
    ) async throws {
        guard let convex else {
            throw NSError(
                domain: "Palmier.Feedback",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Backend not configured."]
            )
        }
        var args: [String: ConvexEncodable?] = [
            "message": message,
            "mayContact": mayContact,
            "appVersion": appVersion,
            "osVersion": osVersion,
        ]
        if let email { args["email"] = email }
        if let screenshotPngBase64 { args["screenshotPngBase64"] = screenshotPngBase64 }
        let _: OkResponse = try await convex.action("feedback:send", with: args)
    }

    func manageSubscription() async {
        lastError = nil
        guard let convex else { return }
        do {
            let result: UrlResponse = try await convex.action(
                "billing:createPortalSession"
            )
            openInBrowser(result.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func openInBrowser(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host,
              Self.allowedBillingHosts.contains(host)
        else {
            lastError = "Refused to open untrusted URL."
            return
        }
        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
    }
}

// MARK: - Display helpers

extension AccountService {
    var displayPrimaryText: String {
        if !isSignedIn { return "Signed out" }
        let user = account?.user
        return user?.displayName ?? user?.email ?? "Signed in"
    }

    var displaySecondaryText: String? {
        guard isSignedIn else { return nil }
        let user = account?.user
        return user?.displayName != nil ? user?.email : nil
    }

    var displayInitial: String {
        guard isSignedIn else { return "" }
        let user = account?.user
        let source = user?.displayName ?? user?.email ?? ""
        return source.first.map { String($0).uppercased() } ?? ""
    }

    func availablePlan(for tier: AccountTier) -> AvailablePlan? {
        availablePlans.first { $0.tier == tier }
    }
}
