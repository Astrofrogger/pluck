import Foundation
import Security

/// All of Pluck's secrets (review link keys, NAS host and API keys, Edit Anywhere pairings, Library codes) in ONE
/// login-keychain item. Pluck is signed with its own certificate, not a Developer ID, so macOS ties a keychain item to
/// each build and asks for the password once per item after every update; with one item it asks once (owner, 2026-11-16).
/// Old separate items move in the first time they're asked for, then they're deleted.
final class PluckVault: @unchecked Sendable {
    static let shared = PluckVault(backend: KeychainBackend())

    /// Where the vault and the old items live (the real keychain, or a dictionary in tests).
    protocol Backend: AnyObject {
        func read(service: String, account: String) -> Data?
        func write(_ data: Data, service: String, account: String)
        func delete(service: String, account: String)
    }

    static let service = "Pluck", account = "secrets"

    private let backend: Backend
    private let lock = NSLock()
    /// service → account → secret; read from the keychain once.
    private var secrets: [String: [String: Data]]?

    init(backend: Backend) { self.backend = backend }

    func load(_ account: String, service: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let data = open()[service]?[account] { return data }
        // Not in the vault yet: an item from before 4.0.4 moves in (one password prompt for it, once).
        guard let old = backend.read(service: service, account: account) else { return nil }
        secrets?[service, default: [:]][account] = old
        persist()
        backend.delete(service: service, account: account)
        return old
    }

    func save(_ data: Data, as account: String, service: String) {
        lock.lock(); defer { lock.unlock() }
        _ = open()
        secrets?[service, default: [:]][account] = data
        persist()
        backend.delete(service: service, account: account)
    }

    func delete(_ account: String, service: String) {
        lock.lock(); defer { lock.unlock() }
        _ = open()
        if secrets?[service]?.removeValue(forKey: account) != nil { persist() }
        backend.delete(service: service, account: account)
    }

    /// (Called with the lock held.)
    private func open() -> [String: [String: Data]] {
        if let secrets { return secrets }
        let stored = backend.read(service: Self.service, account: Self.account)
            .flatMap { try? JSONDecoder().decode([String: [String: Data]].self, from: $0) } ?? [:]
        secrets = stored
        return stored
    }

    private func persist() {
        guard let secrets, let data = try? JSONEncoder().encode(secrets) else { return }
        backend.write(data, service: Self.service, account: Self.account)
    }

    /// The login keychain, generic passwords, this device only.
    final class KeychainBackend: Backend {
        private func query(_ service: String, _ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        }

        func read(service: String, account: String) -> Data? {
            var item = query(service, account)
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }

        func write(_ data: Data, service: String, account: String) {
            let update: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(query(service, account) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
                var item = query(service, account)
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(item as CFDictionary, nil)
            }
        }

        func delete(service: String, account: String) {
            SecItemDelete(query(service, account) as CFDictionary)
        }
    }

    /// Tests: a dictionary instead of the keychain.
    final class MemoryBackend: Backend {
        var items: [String: Data] = [:]
        var reads = 0
        func read(service: String, account: String) -> Data? { reads += 1; return items[service + "/" + account] }
        func write(_ data: Data, service: String, account: String) { items[service + "/" + account] = data }
        func delete(service: String, account: String) { items[service + "/" + account] = nil }
    }
}
