import Foundation

/// Selects where the app's compute backend lives. `.cloud` is the stock Convex +
/// Clerk path; `.local` routes generation / transcription / catalog to a
/// localhost palmier-gateway (fork-only, no account, no credits, no network).
///
/// Chosen once at launch from `PALMIER_BACKEND=local` or the `palmier.backendMode`
/// default. Fork adaptation — keep the diff localized so it rebases onto upstream.
enum BackendMode: String {
    case cloud
    case local

    static let current: BackendMode = {
        let env = ProcessInfo.processInfo.environment
        if env["PALMIER_BACKEND"]?.lowercased() == "local" { return .local }
        if UserDefaults.standard.string(forKey: "palmier.backendMode") == "local" { return .local }
        return .cloud
    }()

    var isLocal: Bool { self == .local }
}

enum LocalGateway {
    static let baseURL: URL = {
        if let s = ProcessInfo.processInfo.environment["PALMIER_GATEWAY_URL"], let u = URL(string: s) {
            return u
        }
        return URL(string: "http://localhost:5474")!
    }()
}
