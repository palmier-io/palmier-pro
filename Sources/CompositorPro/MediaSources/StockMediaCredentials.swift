import Foundation

/// The user's free Pexels API key. Held in the Keychain rather than UserDefaults because it is
/// a credential, and read off the main actor because a Keychain query is a blocking call.
enum StockMediaCredentials {
    private static let pexelsAccount = "stock-media-pexels-api-key"
    private static let pixabayAccount = "stock-media-pixabay-api-key"

    static func pexelsKey() async -> String {
        await storedKey(account: pexelsAccount)
    }

    static func setPexelsKey(_ key: String?) async {
        await store(key, account: pexelsAccount)
    }

    static func pixabayKey() async -> String {
        await storedKey(account: pixabayAccount)
    }

    static func setPixabayKey(_ key: String?) async {
        await store(key, account: pixabayAccount)
    }

    private static func storedKey(account: String) async -> String {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.resume(returning: KeychainStore.load(account: account) ?? "")
            }
        }
    }

    private static func store(_ key: String?, account: String) async {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                if trimmed.isEmpty {
                    KeychainStore.delete(account: account)
                } else {
                    KeychainStore.save(trimmed, account: account)
                }
                continuation.resume(returning: ())
            }
        }
    }
}
