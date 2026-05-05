import Foundation
import AppKit
import Network

private struct FeishuTokenBundle: Codable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpireAt: Date
    var refreshTokenExpireAt: Date
}

enum FeishuOAuthError: LocalizedError {
    case missingAppCredentials
    case authorizationCancelled
    case callbackTimeout
    case invalidCallback(String)
    case tokenExchangeFailed(String)
    case notAuthorized
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAppCredentials:
            return "请先在设置中填写飞书 App ID 和 App Secret"
        case .authorizationCancelled:
            return "授权已取消"
        case .callbackTimeout:
            return "授权超时，请重试"
        case .invalidCallback(let msg):
            return "回调无效：\(msg)"
        case .tokenExchangeFailed(let msg):
            return "换取 access_token 失败：\(msg)"
        case .notAuthorized:
            return "尚未完成飞书授权，请先点击「授权飞书任务」"
        case .refreshFailed(let msg):
            return "刷新 access_token 失败：\(msg)"
        }
    }
}

@MainActor
final class FeishuOAuthService {
    static let shared = FeishuOAuthService()

    private static let keychainService = "com.tictracker.keychain"
    private static let callbackPathConst = "/feishu/callback"
    static let keychainAccount = "feishu-oauth-bundle"
    static let callbackPort: UInt16 = 53017
    static var callbackPath: String { callbackPathConst }
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)\(callbackPathConst)" }

    private static let scopes: [String] = [
        "task:task:readonly",
        "task:tasklist:read",
        "contact:user.id:readonly"
    ]

    private var pendingState: String?
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var listener: NWListener?
    private var timeoutTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private var cachedBundle: FeishuTokenBundle?
    private var didLoadBundle = false

    private let accessTokenRefreshBuffer: TimeInterval = 5 * 60
    private let refreshTokenRenewBuffer: TimeInterval = 6 * 60 * 60

    var isAuthorized: Bool {
        ensureBundleLoaded() != nil
    }

    func clear() {
        cachedBundle = nil
        didLoadBundle = true
        var creds = FeishuCredentials.load()
        creds.oauthBundle = nil
        FeishuCredentials.save(creds)
    }

    /// 启动 OAuth 流程：起本地回调服务器、打开浏览器、等回调、换 token
    func authorize(appID: String, appSecret: String) async throws {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw FeishuOAuthError.missingAppCredentials
        }

        let state = UUID().uuidString
        pendingState = state

        try startCallbackListener()
        defer { stopCallbackListener() }

        var components = URLComponents(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: appID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " "))
        ]
        guard let authURL = components.url else {
            throw FeishuOAuthError.invalidCallback("无法构造授权 URL")
        }

        DevLog.shared.info("FeishuOAuth", "打开浏览器授权: \(authURL.absoluteString)")
        NSWorkspace.shared.open(authURL)

        let code = try await waitForCallback(state: state)
        DevLog.shared.info("FeishuOAuth", "收到授权码，开始换 token")
        let bundle = try await exchangeToken(appID: appID, appSecret: appSecret, code: code)
        saveBundle(bundle)
        DevLog.shared.info("FeishuOAuth", "授权完成，access_token 有效至 \(bundle.accessTokenExpireAt), refresh_token 有效至 \(bundle.refreshTokenExpireAt)")
    }

    /// 取一个有效的 user_access_token，必要时自动续期
    func validAccessToken(appID: String, appSecret: String) async throws -> String {
        guard let bundle = ensureBundleLoaded() else {
            throw FeishuOAuthError.notAuthorized
        }
        let now = Date()
        let accessRemaining = bundle.accessTokenExpireAt.timeIntervalSince(now)
        let refreshRemaining = bundle.refreshTokenExpireAt.timeIntervalSince(now)
        if accessRemaining > accessTokenRefreshBuffer {
            if !bundle.refreshToken.isEmpty,
               refreshRemaining > 0,
               refreshRemaining <= refreshTokenRenewBuffer {
                do {
                    DevLog.shared.info("FeishuOAuth", "refresh_token 即将过期，提前续期 [remaining=\(Int(refreshRemaining))s]")
                    return try await refreshAccessToken(appID: appID, appSecret: appSecret, currentBundle: bundle)
                } catch {
                    DevLog.shared.error("FeishuOAuth", "提前续期 refresh_token 失败，暂用现有 access_token：\(error.localizedDescription)")
                    return bundle.accessToken
                }
            }
            return bundle.accessToken
        }
        // 没有 refresh_token：只能让用户重新授权
        if bundle.refreshToken.isEmpty {
            DevLog.shared.error("FeishuOAuth", "access_token 已过期且没有 refresh_token，请重新授权")
            clear()
            throw FeishuOAuthError.notAuthorized
        }
        if refreshRemaining <= 0 {
            DevLog.shared.error("FeishuOAuth", "refresh_token 也过期了，需要重新授权")
            clear()
            throw FeishuOAuthError.notAuthorized
        }

        if let task = refreshTask {
            return try await task.value
        }
        let task = Task<String, Error> { [self] in
            defer { refreshTask = nil }
            return try await refreshAccessToken(appID: appID, appSecret: appSecret, currentBundle: bundle)
        }
        refreshTask = task
        return try await task.value
    }

    func refreshIfNeededOnWake(appID: String, appSecret: String) async {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else { return }
        do {
            _ = try await validAccessToken(appID: appID, appSecret: appSecret)
        } catch FeishuOAuthError.notAuthorized {
            DevLog.shared.error("FeishuOAuth", "系统唤醒后检查授权失败，需要重新授权")
        } catch {
            DevLog.shared.error("FeishuOAuth", "系统唤醒后刷新 token 失败：\(error.localizedDescription)")
        }
    }

    func forceRefreshAccessToken(appID: String, appSecret: String) async throws -> String {
        guard let bundle = ensureBundleLoaded() else {
            throw FeishuOAuthError.notAuthorized
        }
        let now = Date()
        guard !bundle.refreshToken.isEmpty, bundle.refreshTokenExpireAt > now else {
            clear()
            throw FeishuOAuthError.notAuthorized
        }
        if let task = refreshTask {
            return try await task.value
        }
        let task = Task<String, Error> { [self] in
            defer { refreshTask = nil }
            return try await refreshAccessToken(appID: appID, appSecret: appSecret, currentBundle: bundle)
        }
        refreshTask = task
        return try await task.value
    }

    // MARK: - Callback URL handling

    /// 由 AppDelegate 在收到自定义 URL scheme 时调用（备用通道）
    func handleCallback(url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return processCallbackQuery(components.queryItems ?? [])
    }

    @discardableResult
    private func processCallbackQuery(_ items: [URLQueryItem]) -> Bool {
        let query = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        if let error = query["error"] {
            pendingContinuation?.resume(throwing: FeishuOAuthError.invalidCallback(error))
            pendingContinuation = nil
            return true
        }
        guard let state = query["state"], state == pendingState else {
            pendingContinuation?.resume(throwing: FeishuOAuthError.invalidCallback("state 不匹配"))
            pendingContinuation = nil
            return false
        }
        guard let code = query["code"], !code.isEmpty else {
            pendingContinuation?.resume(throwing: FeishuOAuthError.invalidCallback("缺少 code"))
            pendingContinuation = nil
            return false
        }
        pendingContinuation?.resume(returning: code)
        pendingContinuation = nil
        return true
    }

    private func waitForCallback(state: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            self.timeoutTask?.cancel()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard let self else { return }
                if self.pendingContinuation != nil {
                    self.pendingContinuation?.resume(throwing: FeishuOAuthError.callbackTimeout)
                    self.pendingContinuation = nil
                    self.stopCallbackListener()
                }
            }
        }
    }

    // MARK: - Local HTTP server

    private func startCallbackListener() throws {
        stopCallbackListener()
        let parameters = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: Self.callbackPort)!
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw FeishuOAuthError.invalidCallback("本地回调端口 \(Self.callbackPort) 占用：\(error.localizedDescription)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleIncomingConnection(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        DevLog.shared.info("FeishuOAuth", "本地回调监听已启动 :\(Self.callbackPort)")
    }

    private func stopCallbackListener() {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = request.split(separator: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                var pathPart = parts.count >= 2 ? String(parts[1]) : ""
                if !pathPart.hasPrefix("/") { pathPart = "/" + pathPart }

                var ok = false
                if let url = URL(string: "http://localhost\(pathPart)"),
                   let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   url.path == Self.callbackPathConst {
                    ok = self.processCallbackQuery(comps.queryItems ?? [])
                }

                let body = ok
                    ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:60px;'><h2>授权成功</h2><p>可以关闭此页面，回到 TicTracker。</p></body></html>"
                    : "<html><body style='font-family:-apple-system;text-align:center;padding-top:60px;'><h2>授权失败</h2><p>请回到 TicTracker 查看错误并重试。</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: - Token endpoints (Authen v2)

    private func exchangeToken(appID: String, appSecret: String, code: String) async throws -> FeishuTokenBundle {
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": appID,
            "client_secret": appSecret,
            "code": code,
            "redirect_uri": Self.redirectURI
        ]
        return try await postTokenRequest(body: body, action: "exchange")
    }

    private func refreshAccessToken(appID: String, appSecret: String, currentBundle: FeishuTokenBundle) async throws -> String {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": appID,
            "client_secret": appSecret,
            "refresh_token": currentBundle.refreshToken
        ]
        do {
            var bundle = try await postTokenRequest(body: body, action: "refresh")
            if bundle.refreshToken.isEmpty {
                bundle.refreshToken = currentBundle.refreshToken
                bundle.refreshTokenExpireAt = currentBundle.refreshTokenExpireAt
            }
            saveBundle(bundle)
            DevLog.shared.info("FeishuOAuth", "access_token 已自动续期，下次到期 \(bundle.accessTokenExpireAt)，refresh_token 有效至 \(bundle.refreshTokenExpireAt)")
            return bundle.accessToken
        } catch {
            DevLog.shared.error("FeishuOAuth", "续期失败：\(error.localizedDescription)")
            throw FeishuOAuthError.refreshFailed(error.localizedDescription)
        }
    }

    private func postTokenRequest(body: [String: Any], action: String) async throws -> FeishuTokenBundle {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/authen/v2/oauth/token") else {
            throw FeishuOAuthError.tokenExchangeFailed("无法构造 token URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        if status != 200 {
            DevLog.shared.error("FeishuOAuth", "token 接口非 200 [action=\(action), status=\(status), body=\(bodyText.prefix(300))]")
            throw FeishuOAuthError.tokenExchangeFailed("HTTP \(status) \(bodyText.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeishuOAuthError.tokenExchangeFailed("响应不是 JSON: \(bodyText.prefix(200))")
        }
        if let code = json["code"] as? Int, code != 0 {
            let msg = (json["error_description"] as? String) ?? (json["msg"] as? String) ?? bodyText
            throw FeishuOAuthError.tokenExchangeFailed("code=\(code) msg=\(msg)")
        }
        let tokenPayload = (json["data"] as? [String: Any]) ?? json
        guard let accessToken = tokenPayload["access_token"] as? String, !accessToken.isEmpty,
              let expiresIn = intValue(tokenPayload["expires_in"]) ?? intValue(tokenPayload["expire"]) else {
            throw FeishuOAuthError.tokenExchangeFailed("响应缺字段: \(bodyText.prefix(200))")
        }
        let refreshToken = (tokenPayload["refresh_token"] as? String) ?? ""
        let refreshExpiresIn = intValue(tokenPayload["refresh_token_expires_in"])
            ?? intValue(tokenPayload["refresh_expires_in"])
            ?? intValue(tokenPayload["refresh_token_expire"])
            ?? (30 * 24 * 3600)
        let now = Date()
        return FeishuTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpireAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            refreshTokenExpireAt: refreshToken.isEmpty ? now : now.addingTimeInterval(TimeInterval(refreshExpiresIn))
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: - Persistence

    /// 启动或首次访问时调用一次，后续都走内存缓存
    func warmUp() {
        _ = ensureBundleLoaded()
    }

    func warmUpFromBatch(_ data: Data?) {
        guard !didLoadBundle, let data = data else { return }
        didLoadBundle = true
        cachedBundle = try? JSONDecoder().decode(FeishuTokenBundle.self, from: data)
        DevLog.shared.info("FeishuOAuth", "从统一凭据预热 OAuth bundle [success=\(cachedBundle != nil)]")
    }

    private func ensureBundleLoaded() -> FeishuTokenBundle? {
        if !didLoadBundle {
            didLoadBundle = true
            cachedBundle = loadBundleFromKeychain()
        }
        return cachedBundle
    }

    private func loadBundleFromKeychain() -> FeishuTokenBundle? {
        guard let data = FeishuCredentials.load().oauthBundle else {
            DevLog.shared.info("FeishuOAuth", "Keychain 中没有 OAuth bundle")
            return nil
        }
        let bundle = try? JSONDecoder().decode(FeishuTokenBundle.self, from: data)
        DevLog.shared.info("FeishuOAuth", "从 Keychain 加载 OAuth bundle [success=\(bundle != nil)]")
        return bundle
    }

    private func saveBundle(_ bundle: FeishuTokenBundle) {
        cachedBundle = bundle
        didLoadBundle = true
        if let data = try? JSONEncoder().encode(bundle) {
            var creds = FeishuCredentials.load()
            creds.oauthBundle = data
            if FeishuCredentials.save(creds) {
                DevLog.shared.info("FeishuOAuth", "OAuth bundle 已保存到 Keychain")
            }
        }
    }
}
