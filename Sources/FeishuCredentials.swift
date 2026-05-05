import Foundation

struct FeishuCredentials: Codable {
    var appSecret: String?
    var oauthBundle: Data?
    var webhookSecrets: [String: String] = [:]

    static let keychainService = "com.tictracker.keychain"
    static let keychainAccount = "feishu-credentials"

    private static func logInfo(_ message: String) {
        Task { @MainActor in
            DevLog.shared.info("FeishuCredentials", message)
        }
    }

    private static func logError(_ message: String) {
        Task { @MainActor in
            DevLog.shared.error("FeishuCredentials", message)
        }
    }

    static func load() -> FeishuCredentials {
        if let data = KeychainHelper.load(service: keychainService, account: keychainAccount),
           let creds = try? JSONDecoder().decode(FeishuCredentials.self, from: data) {
            logInfo("已加载统一凭据 [appSecret=\(creds.appSecret?.isEmpty == false), oauth=\(creds.oauthBundle != nil), webhooks=\(creds.webhookSecrets.count)]")
            return creds
        }
        logInfo("统一凭据不存在或无法解码，尝试迁移旧 Keychain 项")
        return migrate()
    }

    @discardableResult
    static func save(_ credentials: FeishuCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let ok = KeychainHelper.save(service: keychainService, account: keychainAccount, data: data)
        if ok {
            logInfo("已保存统一凭据 [appSecret=\(credentials.appSecret?.isEmpty == false), oauth=\(credentials.oauthBundle != nil), webhooks=\(credentials.webhookSecrets.count)]")
        } else {
            logError("保存统一凭据失败")
        }
        return ok
    }

    private static func migrate() -> FeishuCredentials {
        var creds = FeishuCredentials()
        let all = KeychainHelper.loadAll(service: keychainService)

        logInfo("开始迁移旧 Keychain 项，共 \(all.count) 项")

        for (account, data) in all {
            if account == "feishu-app-secret", let str = String(data: data, encoding: .utf8) {
                creds.appSecret = str
                logInfo("迁移 app secret")
            } else if account == "feishu-oauth-bundle" {
                creds.oauthBundle = data
                logInfo("迁移 oauth bundle")
            } else if account.hasPrefix("webhook-secret-") {
                let raw = String(account.dropFirst("webhook-secret-".count))
                if let str = String(data: data, encoding: .utf8) {
                    creds.webhookSecrets[raw] = str
                    logInfo("迁移 webhook secret: \(raw)")
                }
            }
        }

        if creds.appSecret != nil || creds.oauthBundle != nil || !creds.webhookSecrets.isEmpty {
            save(creds)
            logInfo("迁移完成")

            for (account, _) in all {
                if account == "feishu-app-secret" || account == "feishu-oauth-bundle" || account.hasPrefix("webhook-secret-") || account == "feishu-user-access-token" {
                    KeychainHelper.delete(service: keychainService, account: account)
                }
            }
        }

        return creds
    }
}
