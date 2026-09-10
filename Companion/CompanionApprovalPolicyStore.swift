import Foundation
import Security

// The app's default access group prevents unrelated processes from changing this
// policy. There is no shared group, synchronization, or UserDefaults fallback.
@MainActor
struct CompanionApprovalPolicyStore {
    let read: () throws -> Bool?
    let write: (Bool) throws -> Void

    static let keychain = Self(read: {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        switch result as? Data {
        case Data([1]): return true
        case Data([0]): return false
        default: throw StoreError(status: errSecDecode)
        }
    }, write: { required in
        let attributes: [String: Any] = [
            kSecValueData as String: Data([required ? 1 : 0]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = itemQuery.merging(attributes) { _, value in value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    })

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.zats.Passtrami.approval-policy",
            kSecAttrAccount as String: "password-access",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(localized: "Approval settings could not be accessed (\(status)). Open Devices settings to choose an approval method.")
        }
    }
}
