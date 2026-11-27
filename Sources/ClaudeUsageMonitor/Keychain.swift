import Foundation
import Security
import UsageCore

/// Generic-password items in the login Keychain.
///
/// Every call here can block while macOS shows a Keychain password prompt, so none of them
/// may run on the main thread.
enum Keychain {
    static func read(service: String, account: String? = nil) -> SecretReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(errSecInternalError) }
            return .found(String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        case let status:
            return .failed(status)
        }
    }

    /// Replaces the item with a new one rather than updating it in place: a new item's access
    /// list trusts the build that created it, so this build can read it later without a prompt.
    static func write(_ data: Data, service: String, account: String) -> OSStatus {
        let base = baseQuery(service: service, account: account)
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // The old item couldn't be deleted; overwrite its value instead.
            let update = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, update as CFDictionary)
        }
        return status
    }

    static func delete(service: String, account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    static func message(for status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        return "\(text) (\(status))"
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The claude.ai session key's Keychain item.
struct SessionKeyKeychainItem: SecretBackend {
    let service = "ClaudeUsageMonitor"
    let account = "sessionKey"

    func read() -> SecretReadResult {
        Keychain.read(service: service, account: account)
    }

    func write(_ value: String?) throws {
        let status = value.map { Keychain.write(Data($0.utf8), service: service, account: account) }
            ?? Keychain.delete(service: service, account: account)
        guard status == errSecSuccess else {
            throw SecretStoreError(Keychain.message(for: status))
        }
    }
}
