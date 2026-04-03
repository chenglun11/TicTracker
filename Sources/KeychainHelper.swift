import Foundation
import Security

enum KeychainHelper {
    static let service = "com.tictracker.keychain"
    static let account = "api-token"

    @discardableResult
    static func save(service: String = service, account: String = account, data: Data) -> Bool {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = service, account: String = account) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func loadAll(service: String) -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }
        var dict: [String: Data] = [:]
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data {
                dict[account] = data
            }
        }
        return dict
    }

    static func delete(service: String = service, account: String = account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 将旧 service 下所有 account 迁移到新 service，只在首次启动时调用
    static func migrateIfNeeded() {
        let legacyServices = ["com.tictracker.jira", "com.tictracker.ai", "com.tictracker.feishu-bot"]
        for legacy in legacyServices {
            let items = loadAll(service: legacy)
            for (account, data) in items {
                // 只在新 service 下不存在时迁移
                if load(service: service, account: account) == nil {
                    let ok = save(service: service, account: account, data: data)
                    guard ok else { continue }  // save 失败则保留旧数据，不删
                }
                delete(service: legacy, account: account)
            }
        }
    }
}
