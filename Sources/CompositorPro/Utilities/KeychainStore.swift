import Foundation
import Security

/// Credentials for the whole app, chosen by how the running binary was signed.
///
/// A signed build keeps everything in the Keychain, which is the only thing that protects
/// a credential at rest. An ad-hoc signed build owns no keychain access group, so macOS
/// prompts for the login password on every read and a grant is voided by the next
/// rebuild — the same prompt returns on every launch. That build reads and writes a
/// `0600` file instead.
enum KeychainStore {
    private static let service: String = Bundle.main.bundleIdentifier ?? "io.compositor.pro"

    /// Signed builds report a team identifier; ad-hoc ones report none.
    private static let isSignedWithTeam: Bool = {
        var running: SecCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let info else { return false }
        let team = (info as NSDictionary)[kSecCodeInfoTeamIdentifier] as? String
        return !(team?.isEmpty ?? true)
    }()

    private static let devStore = DevSecretStore()

    static func save(_ value: String, account: String) {
        guard isSignedWithTeam else { return devStore.save(value, account: account) }
        keychainSave(value, account: account)
    }

    static func load(account: String) -> String? {
        guard isSignedWithTeam else { return devStore.load(account: account) }
        return keychainLoad(account: account)
    }

    static func delete(account: String) {
        guard isSignedWithTeam else { return devStore.delete(account: account) }
        keychainDelete(account: account)
    }

    // MARK: - Keychain

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainSave(_ value: String, account: String) {
        let query = keychainQuery(account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attrs) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func keychainLoad(account: String) -> String? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func keychainDelete(account: String) {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
    }
}
