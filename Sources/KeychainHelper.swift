import Foundation
import Security

private final class KeychainCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]
    private var loadedServices: Set<String> = []

    private func cacheKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    func get(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let data = storage[cacheKey(service: service, account: account)] {
            return data
        }
        if loadedServices.contains(service) {
            return serviceStorage[service]?[account]
        }
        return nil
    }

    func getAll(service: String) -> [String: Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard loadedServices.contains(service) else { return nil }
        return serviceStorage[service] ?? [:]
    }

    func hasLoaded(service: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedServices.contains(service)
    }

    func set(service: String, account: String, data: Data) {
        lock.lock()
        storage[cacheKey(service: service, account: account)] = data
        if loadedServices.contains(service) {
            var items = serviceStorage[service] ?? [:]
            items[account] = data
            serviceStorage[service] = items
        }
        lock.unlock()
    }

    func setAll(service: String, items: [String: Data]) {
        lock.lock()
        loadedServices.insert(service)
        serviceStorage[service] = items
        for (account, data) in items {
            storage[cacheKey(service: service, account: account)] = data
        }
        lock.unlock()
    }

    func remove(service: String, account: String) {
        lock.lock()
        storage.removeValue(forKey: cacheKey(service: service, account: account))
        if loadedServices.contains(service) {
            var items = serviceStorage[service] ?? [:]
            items.removeValue(forKey: account)
            serviceStorage[service] = items
        }
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

    @discardableResult
    static func save(service: String = service, account: String = account, data: Data) -> Bool {
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
            cache.set(service: service, account: account, data: data)
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
            cache.set(service: service, account: account, data: data)
            removeLegacyMirrorDirectory()
            return true
        }
        return false
    }

    static func exists(service: String = service, account: String = account) -> Bool {
        if cache.get(service: service, account: account) != nil {
            return true
        }
        if cache.hasLoaded(service: service) {
            return false
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
        if let cached = cache.get(service: service, account: account) {
            return cached
        }
        if cache.hasLoaded(service: service) {
            return nil
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
            cache.set(service: service, account: account, data: data)
            removeLegacyMirrorDirectory()
            return data
        }
        return nil
    }

    static func loadAll(service: String) -> [String: Data] {
        if let cached = cache.getAll(service: service) {
            return cached
        }

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
                }
            }
        }
        cache.setAll(service: service, items: dict)
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
        cache.remove(service: service, account: account)
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
