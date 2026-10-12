import Foundation
import Security

/// Where tokens are kept between launches.
protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens)
    func clear()
}

/// The real store: the iOS Keychain, so tokens survive closing the app and are
/// encrypted on the device.
struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    init(service: String = "app.sublette.auth", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> AuthTokens? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else {
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Readable after the first unlock, so a background refresh can use it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    func clear() {
        _ = SecItemDelete(query as CFDictionary)
    }
}

/// Keeps tokens in memory only. Used by tests and previews.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(_ tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() -> AuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func save(_ tokens: AuthTokens) {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}
