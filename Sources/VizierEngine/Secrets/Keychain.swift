import Foundation
import Security

/// API keys live in the login keychain as generic passwords under Vizier's service name. The item
/// is written by the Vizier binary itself (`Vizier --store-key gemini`), so its access list names
/// Vizier's signature and a rebuild signed with the same identity reads it without a prompt.
public enum Keychain {
    public static let service = "net.praxient.dictum"

    public struct Failure: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "keychain error \(status): \(message)"
        }
    }

    /// The secret stored for `account`, or nil when there is none.
    public static func read(_ account: String) throws(Failure) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    /// Stores `secret` for `account`, replacing any earlier value.
    public static func store(_ secret: String, account: String) throws(Failure) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Vizier \(account) API key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        default:
            throw Failure(status: updated)
        }
    }
}
