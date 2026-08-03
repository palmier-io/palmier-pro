import Foundation
import Security

enum KeychainStore {
    private static let service: String = Bundle.main.bundleIdentifier ?? "io.palmier.pro"

    /// Ad-hoc debug builds change code-directory hash every rebuild, so Keychain
    /// ACLs from "Always Allow" stop matching and macOS prompts again. Store
    /// secrets in Application Support for those builds instead.
    private static let usesFileBackend = isAdHocSigned()

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        if usesFileBackend {
            _ = deleteKeychainItem(account: account)
            return saveFile(value, account: account)
        }
        return saveKeychain(value, account: account)
    }

    static func load(account: String) -> String? {
        if usesFileBackend {
            if let value = loadFile(account: account) { return value }
            // Migrate a still-readable Keychain item into the file backend once.
            if let value = loadKeychain(account: account) {
                _ = saveFile(value, account: account)
                _ = deleteKeychainItem(account: account)
                return value
            }
            return nil
        }
        return loadKeychain(account: account)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let fileDeleted = deleteFile(account: account)
        let keychainDeleted = deleteKeychainItem(account: account)
        return fileDeleted && keychainDeleted
    }

    // MARK: - Keychain

    private static func saveKeychain(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        // Replace any existing item so the ACL matches this binary.
        _ = deleteKeychainItem(account: account)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            _ = deleteOrphanedItem(account: account)
            addStatus = SecItemAdd(item as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            Log.agent.error("keychain save failed account=\(account) status=\(addStatus)")
            return false
        }
        return true
    }

    private static func loadKeychain(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.agent.warning("keychain load failed account=\(account) status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    private static func deleteKeychainItem(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        }
        Log.agent.warning("keychain delete failed account=\(account) status=\(status)")
        return deleteOrphanedItem(account: account)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Ad-hoc rebuilds leave Keychain ACLs bound to an old code directory hash.
    /// Those items often reject SecItemDelete from the new binary, but still
    /// allow `/usr/bin/security`, which is listed on the ACL.
    @discardableResult
    private static func deleteOrphanedItem(account: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", service,
            "-a", account,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.agent.warning("keychain security delete failed account=\(account): \(error.localizedDescription)")
            return false
        }
        if process.terminationStatus == 0 {
            return true
        }
        Log.agent.warning("keychain security delete failed account=\(account) status=\(process.terminationStatus)")
        return false
    }

    // MARK: - File backend (ad-hoc)

    private static func secretsDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent(service, isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileURL(account: String) throws -> URL {
        let safe = account
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return try secretsDirectory().appendingPathComponent(safe, isDirectory: false)
    }

    private static func saveFile(_ value: String, account: String) -> Bool {
        do {
            let url = try fileURL(account: account)
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try Data(value.utf8).write(to: temporary, options: .atomic)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            Log.agent.error("secret file save failed account=\(account): \(error.localizedDescription)")
            return false
        }
    }

    private static func loadFile(account: String) -> String? {
        do {
            let url = try fileURL(account: account)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            Log.agent.warning("secret file load failed account=\(account): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private static func deleteFile(account: String) -> Bool {
        do {
            let url = try fileURL(account: account)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            Log.agent.warning("secret file delete failed account=\(account): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Signing

    private static func isAdHocSigned() -> Bool {
        let url = Bundle.main.executableURL ?? Bundle.main.bundleURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return true }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information = information as NSDictionary? else { return true }
        // Ad-hoc signatures have no team identifier. Developer ID / App Store builds do.
        if information[kSecCodeInfoTeamIdentifier] == nil { return true }
        // flags bit 0x2 is ad-hoc (kSecCodeSignatureAdhoc).
        if let codeFlags = information[kSecCodeInfoFlags] as? UInt32 {
            return (codeFlags & 0x2) != 0
        }
        return false
    }
}
