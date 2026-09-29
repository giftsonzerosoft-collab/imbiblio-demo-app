import Foundation

#if canImport(Security)
import Security

/// Keychain-backed `TokenStore` — the production implementation on iOS.
///
/// Tokens are `kSecClassGenericPassword` items. `kSecAttrAccessibleAfterFirstUnlock`
/// is chosen so a background download can refresh the token while the device is
/// locked, but the item is never synchronised to iCloud and never included in a
/// device backup.
public struct KeychainTokenStore: TokenStore {

    private let service: String
    private let account: String

    public init(service: String = "com.example.iBiblioDemo", account: String = "oauth-token") {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() async throws -> AuthToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            do {
                return try JSONDecoder.json.decode(AuthToken.self, from: data)
            } catch {
                throw AuthError.tokenStoreFailure("Stored token is corrupt: \(error)")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.tokenStoreFailure("Keychain read failed (OSStatus \(status))")
        }
    }

    public func save(_ token: AuthToken) async throws {
        let data: Data
        do {
            data = try JSONEncoder.json.encode(token)
        } catch {
            throw AuthError.tokenStoreFailure("Cannot encode token: \(error)")
        }

        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthError.tokenStoreFailure("Keychain write failed (OSStatus \(addStatus))")
            }
        } else {
            throw AuthError.tokenStoreFailure("Keychain update failed (OSStatus \(updateStatus))")
        }
    }

    public func clear() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.tokenStoreFailure("Keychain delete failed (OSStatus \(status))")
        }
    }
}
#endif
