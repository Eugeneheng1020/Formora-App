import Foundation
import Security

/// Where API keys live. The app uses the Keychain; tests and previews use memory.
protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ secret: String, for account: String) throws
    func delete(_ account: String) throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus

    var message: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "钥匙串错误（\(status)）"
    }
}

/// Generic passwords in the classic Keychain, one service per profile (so `qa` never sees real keys).
/// The build is signed with a stable team identity, so macOS recognises the same app across builds and
/// stops asking for the login password (old app 2026-09-05: ad-hoc signing was the cause, not the Keychain).
/// The data-protection Keychain would need a provisioning profile; see the phase 4 plan.
struct KeychainSecretStore: SecretStore {
    static let baseService = "com.eugenecheng.formora.providers"

    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Formora · \(account)"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Profile reset: removes every key this service holds.
    func deleteAll() {
        let all = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary
        for _ in 0..<200 where SecItemDelete(all) == errSecSuccess {}
    }
}

/// Keys in memory only. `readCount` lets tests check the Keychain is read once per run.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var reads = 0

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    var readCount: Int { lock.withLock { reads } }

    func read(_ account: String) throws -> String? {
        lock.withLock {
            reads += 1
            return items[account]
        }
    }

    func write(_ secret: String, for account: String) throws {
        lock.withLock { items[account] = secret }
    }

    func delete(_ account: String) throws {
        lock.withLock { items[account] = nil }
    }
}
