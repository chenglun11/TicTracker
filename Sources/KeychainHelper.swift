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

    private static func mirrorDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("TicTracker/keychain-mirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func mirrorURL(service: String, account: String) -> URL? {
        guard let dir = mirrorDirectoryURL() else { return nil }
        let safeService = service.replacingOccurrences(of: "/", with: "_")
        let safeAccount = account.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safeService)__\(safeAccount).bin")
    }

    @discardableResult
    private static func saveMirror(service: String, account: String, data: Data) -> Bool {
        guard let url = mirrorURL(service: service, account: account) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func loadMirror(service: String, account: String) -> Data? {
        guard let url = mirrorURL(service: service, account: account) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func deleteMirror(service: String, account: String) {
        guard let url = mirrorURL(service: service, account: account) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func cacheKey(service: String, account: String) -> String {
        "\(service)::\(account)"
    }

    @discardableResult
    static func save(service: String = service, account: String = account, data: Data) -> Bool {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let keychainSuccess = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        let mirrorSuccess = saveMirror(service: service, account: account, data: data)
        if keychainSuccess || mirrorSuccess {
            cache.set(cacheKey(service: service, account: account), data: data)
        }
        return keychainSuccess || mirrorSuccess
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
            _ = saveMirror(service: service, account: account, data: data)
            return data
        }

        if let mirrored = loadMirror(service: service, account: account) {
            _ = save(service: service, account: account, data: mirrored)
            cache.set(key, data: mirrored)
            return mirrored
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
                    _ = saveMirror(service: service, account: account, data: data)
                }
            }
        }
        if let dir = mirrorDirectoryURL(),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let safeService = service.replacingOccurrences(of: "/", with: "_")
            let prefix = "\(safeService)__"
            for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "bin" {
                let raw = String(file.lastPathComponent.dropFirst(prefix.count).dropLast(".bin".count))
                guard dict[raw] == nil, let data = try? Data(contentsOf: file) else { continue }
                dict[raw] = data
                cache.set(cacheKey(service: service, account: raw), data: data)
            }
        }
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
        deleteMirror(service: service, account: account)
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
