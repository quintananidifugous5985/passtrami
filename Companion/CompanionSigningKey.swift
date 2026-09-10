import Foundation
import LocalAuthentication
import Security

struct CompanionSigningKey: Sendable {
    let tag: Data
    let requiresPresence: Bool

    func publicKey() throws -> Data {
        let key = try loadOrCreate()
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw CompanionError.message("Could not read the device signing key.")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw CompanionError.message("Could not read the device signing key.")
        }
        return data as Data
    }

    func sign(_ data: Data, reason: String) async throws -> Data {
        try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            context.touchIDAuthenticationAllowableReuseDuration = 0
            defer { context.invalidate() }
            let key = try load(context: context)
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                        data as CFData, &error) else {
                if let error { throw error.takeRetainedValue() }
                throw CompanionError.message("Device authentication did not complete.")
            }
            return signature as Data
        }.value
    }

    private func load(context: LAContext? = nil) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            throw CompanionError.message(status == errSecItemNotFound
                ? "The device signing key is missing. Unpair the devices and pair them again."
                : "Could not access the device signing key (\(status)).")
        }
        return result as! SecKey
    }

    private func loadOrCreate() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let result { return result as! SecKey }
        guard status == errSecItemNotFound else {
            throw CompanionError.message("Could not access the device signing key (\(status)).")
        }
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = requiresPresence ? [.privateKeyUsage, .userPresence] : []
        let accessibility = requiresPresence ? kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility,
                                                           flags, &error) else {
            throw CompanionError.message("Could not protect the device signing key.")
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access
            ]
        ]
        if requiresPresence { attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CompanionError.message(requiresPresence
                ? "Set a passcode on your iPhone to use device approval. A physical iPhone is required."
                : "Could not create the device signing key.")
        }
        return key
    }
}
