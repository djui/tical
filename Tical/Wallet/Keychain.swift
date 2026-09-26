import Foundation
import Security

/// Keychain storage for pass signing. Items stay on this device: they don't sync to iCloud
/// Keychain and can't be restored onto another device.
nonisolated enum Keychain {
    struct Failure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "The keychain refused the change: \(message)")
        }
    }

    private static let service = "com.tical.pass-signing"

    // MARK: - Data

    static func data(for account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func setData(_ data: Data, for account: String) throws {
        deleteData(for: account)
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func deleteData(for account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keys

    /// Creates an RSA 2048 key, the kind a Pass Type ID certificate needs, and keeps it in the keychain.
    static func makePrivateKey(tag: String) throws -> SecKey {
        deleteKey(tag: tag)
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [],
            nil
        ) else { throw Failure(status: errSecParam) }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Data(tag.utf8),
                kSecAttrAccessControl: access,
                kSecAttrLabel: "Tical pass signing key",
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? Failure(status: errSecParam)
        }
        return key
    }

    /// Keeps a private key that came from somewhere else, such as a .p12 file.
    static func storePrivateKey(_ key: SecKey, tag: String) throws {
        deleteKey(tag: tag)
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel: "Tical pass signing key",
            kSecValueRef: key,
        ]
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            // Some imported keys can't be stored by reference; store their bytes instead.
            var error: Unmanaged<CFError>?
            guard let bytes = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw Failure(status: status) }
            attributes[kSecValueRef] = nil
            attributes[kSecValueData] = bytes
            attributes[kSecAttrKeyType] = kSecAttrKeyTypeRSA
            attributes[kSecAttrKeyClass] = kSecAttrKeyClassPrivate
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func privateKey(tag: String) -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(tag.utf8),
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecKey)
    }

    static func retagKey(from oldTag: String, to newTag: String) throws {
        deleteKey(tag: newTag)
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(oldTag.utf8),
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrApplicationTag: Data(newTag.utf8)] as CFDictionary)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func deleteKey(tag: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(tag.utf8),
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    static func publicKeyBytes(of key: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(key) else { return nil }
        return SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    }

    static func sign(_ data: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? Failure(status: errSecParam)
        }
        return signature
    }
}
