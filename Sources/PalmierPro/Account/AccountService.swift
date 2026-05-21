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
    private(set) var lastError: String?
    private(set) var isBuyingCredits: Bool = false

    var isSignedIn: Bool { !isMisconfigured && Clerk.shared.user != nil }
    var tier: AccountTier { account?.user.tier ?? .none }
    var isPaid: Bool { tier.isPaid }

    var spentCredits: Int { account?.user.spentCreditsThisPeriod ?? 0 }
    var budgetCredits: Int? {
        guard let user = account?.user else { return nil }
        let tierBudget = account?.plan?.monthlyBudgetCredits ?? 0
        let total = tierBudget + (user.purchasedCredits ?? 0)
        return total > 0 ? total : nil
    }

    @ObservationIgnored private(set) var convex: ConvexClientWithAuth<String>?
    @ObservationIgnored private var accountSubscription: AnyCancellable?
    @ObservationIgnored private var authEventTask: Task<Void, Never>?
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

        authEventTask = Task { @MainActor [weak self] in
            await self?.handleInitialAuthState()
            for await event in Clerk.shared.auth.events {
                guard let self else { return }
                switch event {
                case .sessionChanged(_, let new):
                    if new?.status == .active {
                        await provisionAndSubscribe()
                    } else if new == nil {
                        clearAccount()
                    }
                case .signedOut, .accountDeleted:
                    clearAccount()
                default:
                    break
                }
            }
        }
    }

    private func handleInitialAuthState() async {
        for _ in 0..<50 where !Clerk.shared.isLoaded {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isLoading = false
        guard isSignedIn else { return }
        await provisionAndSubscribe()
    }

    private func provisionAndSubscribe() async {
        guard let convex else { return }

        let loginResult = await convex.loginFromCache()
        if case .failure = loginResult {
            try? await Clerk.shared.auth.signOut()
            return
        }

        let user = Clerk.shared.user
        let name = [user?.firstName, user?.lastName]
            .compactMap { $0 }
            .joined(separator: " ")
        let args: [String: ConvexEncodable?] = [
            "email": user?.primaryEmailAddress?.emailAddress,
            "name": name.isEmpty ? nil : name,
            "image": user?.imageUrl,
        ]

        do {
            try await convex.mutation("users:upsertFromAuth", with: args)
        } catch {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try await convex.mutation("users:upsertFromAuth", with: args)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        startAccountSubscription()
    }

    private func startAccountSubscription() {
        accountSubscription?.cancel()
        accountSubscription = convex?
            .subscribe(to: "account:get", yielding: AccountResponse.self)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
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
        do {
            _ = try await Clerk.shared.auth.signInWithOAuth(provider: .google)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        guard !isMisconfigured else { return }
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            lastError = error.localizedDescription
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
        NSWorkspace.shared.open(url)
    }
}
