import Foundation
import Security

private final class KeychainCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, data: Data) {
        lock.lock()
        storage[key] = data
        lock.unlock()
    }

    func remove(_ key: String) {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }
}

enum KeychainHelper {
    static let service = "com.tictracker.keychain"
    static let account = "api-token"
    private static let migrationFlagKey = "keychainMigrationDone"
    private static let cache = KeychainCache()

    private static func legacyMirrorDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("TicTracker/keychain-mirror", isDirectory: true)
    }

    private static func removeLegacyMirrorDirectory() {
        guard let dir = legacyMirrorDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func cacheKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    @discardableResult
    static func save(service: String = service, account: String = account, data: Data) -> Bool {
        let key = cacheKey(service: service, account: account)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            cache.set(key, data: data)
            removeLegacyMirrorDirectory()
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = lookup
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            cache.set(key, data: data)
            removeLegacyMirrorDirectory()
            return true
        }
        return false
    }

    static func exists(service: String = service, account: String = account) -> Bool {
        if cache.get(cacheKey(service: service, account: account)) != nil {
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = service, account: String = account) -> Data? {
        let key = cacheKey(service: service, account: account)
        if let cached = cache.get(key) {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            cache.set(key, data: data)
            removeLegacyMirrorDirectory()
            return data
        }
        return nil
    }

    static func loadAll(service: String) -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var dict: [String: Data] = [:]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   let data = item[kSecValueData as String] as? Data {
                    dict[account] = data
                    cache.set(cacheKey(service: service, account: account), data: data)
                }
            }
        }
        removeLegacyMirrorDirectory()
        return dict
    }

    static func warmUpAccess() {
        _ = loadAll(service: service)
        _ = loadAll(service: "com.tictracker.sync")
    }

    static func delete(service: String = service, account: String = account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cache.remove(cacheKey(service: service, account: account))
        removeLegacyMirrorDirectory()
    }

    /// 将旧 service 下所有 account 迁移到新 service，只在首次启动时调用
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlagKey) else { return }

        let existingAccounts = Set(loadAll(service: service).keys)
        let legacyServices = ["com.tictracker.jira", "com.tictracker.ai", "com.tictracker.feishu-bot"]
        for legacy in legacyServices {
            let items = loadAll(service: legacy)
            for (account, data) in items {
                if !existingAccounts.contains(account) {
                    let ok = save(service: service, account: account, data: data)
                    guard ok else { continue }
                }
                delete(service: legacy, account: account)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationFlagKey)
    }
}
