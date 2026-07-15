import Foundation
import Security
import LocalAuthentication

private final class KeychainCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]
    private var loadedServices: Set<String> = []
    private var bundle: [String: [String: Data]]?

    private func cacheKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    func get(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[cacheKey(service: service, account: account)]
    }

    func getAll(service: String) -> [String: Data]? {
        lock.lock()
        defer { lock.unlock() }
        guard loadedServices.contains(service) else { return nil }
        return serviceStorage[service] ?? [:]
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

    func getBundle() -> [String: [String: Data]]? {
        lock.lock()
        defer { lock.unlock() }
        return bundle
    }

    func setBundle(_ items: [String: [String: Data]]) {
        lock.lock()
        bundle = items
        for (service, accounts) in items {
            loadedServices.insert(service)
            serviceStorage[service] = accounts
            for (account, data) in accounts {
                storage[cacheKey(service: service, account: account)] = data
            }
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
    private static let bundleAccount = "credential-bundle"
    private static let migrationFlagKey = "keychainMigrationDone"
    private static let cache = KeychainCache()
    private static let legacyServiceAccounts: [String: Set<String>] = [
        "com.tictracker.jira": ["api-token"],
        "com.tictracker.ai": ["api-key", "base-url", "model"],
        "com.tictracker.feishu-bot": ["webhook-secret"],
    ]

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
        if saveToBundle(service: service, account: account, data: data) {
            cache.set(service: service, account: account, data: data)
            removeLegacyMirrorDirectory()
            return true
        }

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
        if bundledData(service: service, account: account) != nil {
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = service, account: String = account) -> Data? {
        if let cached = cache.get(service: service, account: account) {
            return cached
        }

        if let data = bundledData(service: service, account: account) {
            cache.set(service: service, account: account, data: data)
            return data
        }

        if let data = loadDirect(service: service, account: account, allowAuthenticationUI: false) {
            cache.set(service: service, account: account, data: data)
            return data
        }

        for legacyService in legacyServices(for: service, account: account) {
            let migrated = migrateLegacyService(legacyService, to: service)
            if let data = migrated[account] {
                return data
            }
        }
        return nil
    }

    private static func loadDirect(service: String, account: String, allowAuthenticationUI: Bool = false, context: LAContext? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        if !allowAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
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

        if let bundled = bundledItems()[service] {
            cache.setAll(service: service, items: bundled)
            return bundled
        }

        let (status, dict) = loadAllDirect(service: service, allowAuthenticationUI: false)
        if status == errSecSuccess {
            cache.setAll(service: service, items: dict)
        } else if status == errSecItemNotFound {
            cache.setAll(service: service, items: [:])
        }
        removeLegacyMirrorDirectory()
        return dict
    }

    private static func loadAllDirect(service: String, allowAuthenticationUI: Bool = false, context: LAContext? = nil) -> (OSStatus, [String: Data]) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        if !allowAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var dict: [String: Data] = [:]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   let data = item[kSecValueData as String] as? Data {
                    dict[account] = data
                }
            }
        }
        return (status, dict)
    }

    private static func legacyServices(for service: String, account: String) -> [String] {
        guard service == Self.service else { return [] }
        return legacyServiceAccounts.compactMap { legacyService, accounts in
            accounts.contains(account) ? legacyService : nil
        }
    }

    private static func migrateLegacyService(_ legacyService: String, to targetService: String) -> [String: Data] {
        let (status, items) = loadAllDirect(service: legacyService, allowAuthenticationUI: false)
        guard status == errSecSuccess, !items.isEmpty else { return [:] }

        var migrated: [String: Data] = [:]
        for (account, data) in items {
            if let existing = loadDirect(service: targetService, account: account, allowAuthenticationUI: false) {
                migrated[account] = existing
                delete(service: legacyService, account: account)
                continue
            }
            if save(service: targetService, account: account, data: data) {
                migrated[account] = data
                delete(service: legacyService, account: account)
            }
        }
        return migrated
    }

    static func warmUpAccess() {
        // Do not touch Keychain on launch. macOS may ask once per legacy item
        // when app access has not been granted, so migration must not run
        // implicitly at startup.
    }

    static func delete(service: String = service, account: String = account) {
        _ = removeFromBundle(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cache.remove(service: service, account: account)
        removeLegacyMirrorDirectory()
    }

    private static func bundledData(service: String, account: String) -> Data? {
        bundledItems()[service]?[account]
    }

    private static func bundledItems(context: LAContext? = nil) -> [String: [String: Data]] {
        if let cached = cache.getBundle() {
            return cached
        }

        guard let data = loadBundleDirect(context: context),
              let bundle = try? JSONDecoder().decode([String: [String: Data]].self, from: data) else {
            cache.setBundle([:])
            return [:]
        }
        cache.setBundle(bundle)
        removeLegacyMirrorDirectory()
        return bundle
    }

    private static func saveToBundle(service: String, account: String, data: Data) -> Bool {
        guard account != bundleAccount else {
            return saveDirect(service: service, account: account, data: data)
        }
        var bundle = bundledItems()
        var accounts = bundle[service] ?? existingDirectItems(service: service)
        accounts[account] = data
        bundle[service] = accounts
        return saveBundle(bundle)
    }

    private static func removeFromBundle(service: String, account: String) -> Bool {
        guard account != bundleAccount else { return true }
        var bundle = bundledItems()
        guard var accounts = bundle[service], accounts[account] != nil else {
            return true
        }
        accounts.removeValue(forKey: account)
        if accounts.isEmpty {
            bundle.removeValue(forKey: service)
        } else {
            bundle[service] = accounts
        }
        return saveBundle(bundle)
    }

    private static func saveBundle(_ bundle: [String: [String: Data]], context: LAContext? = nil) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle),
              saveDirect(service: service, account: bundleAccount, data: data, context: context) else {
            return false
        }
        cache.setBundle(bundle)
        removeLegacyMirrorDirectory()
        return true
    }

    private static func loadBundleDirect(context: LAContext? = nil) -> Data? {
        loadDirect(service: service, account: bundleAccount, allowAuthenticationUI: true, context: context)
    }

    private static func existingDirectItems(service: String) -> [String: Data] {
        let (status, items) = loadAllDirect(service: service, allowAuthenticationUI: false)
        return status == errSecSuccess ? items : [:]
    }

    @discardableResult
    private static func saveDirect(service: String, account: String, data: Data, context: LAContext? = nil) -> Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]

        var updateLookup = lookup
        if let context {
            updateLookup[kSecUseAuthenticationContext as String] = context
        }
        let updateStatus = SecItemUpdate(updateLookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = lookup
        addQuery.merge(attributes) { _, new in new }
        if let context {
            addQuery[kSecUseAuthenticationContext as String] = context
        }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
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
