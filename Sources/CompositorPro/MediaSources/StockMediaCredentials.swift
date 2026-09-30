import Foundation

/// The user's free Pexels API key. Held in the Keychain rather than UserDefaults because it is
/// a credential, and read off the main actor because a Keychain query is a blocking call.
enum StockMediaCredentials {
    private static let pexelsAccount = "stock-media-pexels-api-key"

    static func pexelsKey() async -> String {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(returning: KeychainStore.load(account: pexelsAccount) ?? "")
            }
        }
    }

    static func setPexelsKey(_ key: String?) async {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                if trimmed.isEmpty {
                    KeychainStore.delete(account: pexelsAccount)
                } else {
                    KeychainStore.save(trimmed, account: pexelsAccount)
                }
                continuation.resume(returning: ())
            }
        }
    }
}
