import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case claude = "Claude"
    case openai = "OpenAI"
}

struct AIConfig: Codable {
    var provider: AIProvider = .claude
    var baseURL: String = ""
    var model: String = ""
    var customPrompt: String = ""

    // 对话设置
    var chatMaxHistory: Int = 10
    var chatSystemPrompt: String = ""
    var chatModel: String = ""

    static let defaultPrompt = """
    你是一个技术支持团队的周报助手。根据提供的原始数据，生成一份简洁专业的周报摘要。
    要求：
    1. 用中文撰写
    2. 包含本周工作概览（总量、趋势）
    3. 按项目/部门总结重点
    4. 如有日报笔记，提炼关键事项
    5. 只总结本周实际完成的工作，不要写展望或计划
    6. 保持简洁，不要过度展开
    """

    static let defaultChatSystemPrompt = """
    你是一个友好的 AI 助手，可以帮助用户解答问题、提供建议和进行对话。
    """

    var effectivePrompt: String {
        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPrompt : trimmed
    }

    var effectiveChatSystemPrompt: String {
        let trimmed = chatSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultChatSystemPrompt : trimmed
    }

    var effectiveChatModel: String {
        let trimmed = chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return effectiveModel // 默认使用周报的模型
    }

    var effectiveBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed }
        switch provider {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        }
    }

    var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch provider {
        case .claude: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o-mini"
        }
    }
}

@MainActor
final class AIService {
    static let shared = AIService()
    private init() {}

    private let log = DevLog.shared
    private let mod = "AI"
    private let keychainService = "com.tictracker.keychain"
    private let keychainAccount = "api-key"
    private let keychainBaseURLAccount = "base-url"
    private let keychainModelAccount = "model"
    private var cachedConfig: StoredConfig?

    struct StoredConfig {
        var apiKey: String
        var baseURL: String
        var model: String
    }

    func loadAll() -> StoredConfig {
        if let cachedConfig { return cachedConfig }
        let all = KeychainHelper.loadAll(service: keychainService)
        let stored = StoredConfig(
            apiKey: all[keychainAccount].flatMap { String(data: $0, encoding: .utf8) } ?? "",
            baseURL: all[keychainBaseURLAccount].flatMap { String(data: $0, encoding: .utf8) } ?? "",
            model: all[keychainModelAccount].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        )
        cachedConfig = stored
        return stored
    }

    func saveAll(apiKey: String, baseURL: String, model: String) {
        save(keychainAccount, value: apiKey)
        save(keychainBaseURLAccount, value: baseURL)
        save(keychainModelAccount, value: model)
    }

    func saveAPIKey(_ key: String) { save(keychainAccount, value: key) }
    func loadAPIKey() -> String? { load(keychainAccount) }

    func saveBaseURL(_ url: String) { save(keychainBaseURLAccount, value: url) }
    func loadBaseURL() -> String? { load(keychainBaseURLAccount) }

    func saveModel(_ model: String) { save(keychainModelAccount, value: model) }
    func loadModel() -> String? { load(keychainModelAccount) }

    func clearAll() {
        for account in [keychainAccount, keychainBaseURLAccount, keychainModelAccount] {
            KeychainHelper.delete(service: keychainService, account: account)
        }
        cachedConfig = StoredConfig(apiKey: "", baseURL: "", model: "")
    }

    private func save(_ account: String, value: String) {
        if let data = value.data(using: .utf8) {
            KeychainHelper.save(service: keychainService, account: account, data: data)
        }
        var current = loadAll()
        switch account {
        case keychainAccount:
            current.apiKey = value
        case keychainBaseURLAccount:
            current.baseURL = value
        case keychainModelAccount:
            current.model = value
        default:
            break
        }
        cachedConfig = current
    }

    private func load(_ account: String) -> String? {
        let current = loadAll()
        switch account {
        case keychainAccount: return current.apiKey
        case keychainBaseURLAccount: return current.baseURL
        case keychainModelAccount: return current.model
        default: return nil
        }
    }

    enum AIError: LocalizedError {
        case noAPIKey
        case requestFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "未配置 API Key"
            case .requestFailed(let msg): return msg
            case .invalidResponse: return "无法解析 AI 响应"
            }
        }
    }

    func generateWeeklyReport(rawReport: String, config: AIConfig) async throws -> String {
        log.info(mod, "开始生成周报，服务商: \(config.provider.rawValue)")
        guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
            log.error(mod, "未配置 API Key")
            throw AIError.noAPIKey
        }

        let systemPrompt = config.effectivePrompt
        let userPrompt = "以下是本周的原始技术支持数据，请生成周报摘要：\n\n\(rawReport)"

        do {
            let result: String
            switch config.provider {
            case .claude: result = try await callClaude(apiKey: apiKey, config: config, system: systemPrompt, user: userPrompt)
            case .openai: result = try await callOpenAI(apiKey: apiKey, config: config, system: systemPrompt, user: userPrompt)
            }
            log.info(mod, "周报生成成功，长度: \(result.count) 字符")
            return result
        } catch {
            log.error(mod, "周报生成失败: \(error.localizedDescription)")
            throw error
        }
    }

    func chat(message: String, attachments: [(fileName: String, content: String, mimeType: String)], history: [(String, String)], config: AIConfig) async throws -> String {
        log.info(mod, "开始对话，服务商: \(config.provider.rawValue), 附件数: \(attachments.count)")
        guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
            log.error(mod, "未配置 API Key")
            throw AIError.noAPIKey
        }

        let systemPrompt = config.effectiveChatSystemPrompt
        let userContent = buildUserContent(message: message, attachments: attachments)

        var chatConfig = config
        chatConfig.model = config.effectiveChatModel

        do {
            let result: String
            switch config.provider {
            case .claude:
                var messages: [[String: String]] = []
                for (role, content) in history {
                    messages.append(["role": role, "content": content])
                }
                messages.append(["role": "user", "content": userContent])
                result = try await callClaudeWithMessages(apiKey: apiKey, config: chatConfig, system: systemPrompt, messages: messages)

            case .openai:
                var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
                for (role, content) in history {
                    messages.append(["role": role, "content": content])
                }
                messages.append(["role": "user", "content": userContent])
                result = try await callOpenAIWithMessages(apiKey: apiKey, config: chatConfig, messages: messages)
            }
            log.info(mod, "对话成功，长度: \(result.count) 字符")
            return result
        } catch {
            log.error(mod, "对话失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 流式对话 — 返回 AsyncThrowingStream，每次 yield 一段 text delta
    func chatStream(message: String, attachments: [(fileName: String, content: String, mimeType: String)], history: [(String, String)], config: AIConfig) throws -> AsyncThrowingStream<String, Error> {
        log.info(mod, "开始流式对话，服务商: \(config.provider.rawValue)")
        guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let systemPrompt = config.effectiveChatSystemPrompt
        let userContent = buildUserContent(message: message, attachments: attachments)

        var chatConfig = config
        chatConfig.model = config.effectiveChatModel

        switch config.provider {
        case .claude:
            var messages: [[String: String]] = []
            for (role, content) in history {
                messages.append(["role": role, "content": content])
            }
            messages.append(["role": "user", "content": userContent])
            return streamClaude(apiKey: apiKey, config: chatConfig, system: systemPrompt, messages: messages)

        case .openai:
            var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            for (role, content) in history {
                messages.append(["role": role, "content": content])
            }
            messages.append(["role": "user", "content": userContent])
            return streamOpenAI(apiKey: apiKey, config: chatConfig, messages: messages)
        }
    }

    private func buildUserContent(message: String, attachments: [(fileName: String, content: String, mimeType: String)]) -> String {
        var userContent = message
        if !attachments.isEmpty {
            userContent += "\n\n附件内容："
            for attachment in attachments {
                if attachment.mimeType.hasPrefix("image/") {
                    userContent += "\n[图片: \(attachment.fileName)]\n(图片已上传但暂不支持视觉分析)"
                } else {
                    userContent += "\n\n文件名: \(attachment.fileName)\n内容:\n\(attachment.content)"
                }
            }
        }
        return userContent
    }

    // MARK: - Claude API (非流式，用于周报等)

    private func callClaude(apiKey: String, config: AIConfig, system: String, user: String) async throws -> String {
        let messages = [["role": "user", "content": user]]
        return try await callClaudeWithMessages(apiKey: apiKey, config: config, system: system, messages: messages)
    }

    private func callClaudeWithMessages(apiKey: String, config: AIConfig, system: String, messages: [[String: String]]) async throws -> String {
        let request = buildClaudeRequest(config: config, apiKey: apiKey, system: system, messages: messages, stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        log.info(mod, "HTTP \(http.statusCode), \(data.count) bytes")
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIError.requestFailed("Claude API 错误: \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError.invalidResponse
        }
        let textParts = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
        guard !textParts.isEmpty else { throw AIError.invalidResponse }
        return textParts.joined(separator: "\n\n")
    }

    // MARK: - OpenAI API (非流式)

    private func callOpenAI(apiKey: String, config: AIConfig, system: String, user: String) async throws -> String {
        let messages = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        return try await callOpenAIWithMessages(apiKey: apiKey, config: config, messages: messages)
    }

    private func callOpenAIWithMessages(apiKey: String, config: AIConfig, messages: [[String: String]]) async throws -> String {
        let request = buildOpenAIRequest(config: config, apiKey: apiKey, messages: messages, stream: false)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        log.info(mod, "HTTP \(http.statusCode), \(data.count) bytes")
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIError.requestFailed("OpenAI API 错误: \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.invalidResponse
        }
        return text
    }

    // MARK: - Streaming

    private func streamClaude(apiKey: String, config: AIConfig, system: String, messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        let request = buildClaudeRequest(config: config, apiKey: apiKey, system: system, messages: messages, stream: true)
        return AsyncThrowingStream { continuation in
            let delegate = SSEDelegate(
                onComplete: { continuation.finish() },
                onError: { continuation.finish(throwing: $0) }
            )
            delegate.onEvent = { [weak delegate] event, data in
                guard let delegate = delegate else { return }
                guard let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

                if event == "content_block_start" {
                    if let block = json["content_block"] as? [String: Any],
                       let type = block["type"] as? String {
                        delegate.currentBlockType = type
                    }
                } else if event == "content_block_delta" {
                    guard delegate.currentBlockType == "text" else { return }
                    if let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        continuation.yield(text)
                    }
                } else if event == "message_stop" {
                    continuation.finish()
                } else if event == "error" {
                    let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "流式响应错误"
                    continuation.finish(throwing: AIError.requestFailed(msg))
                }
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let streamTask = session.dataTask(with: request)
            delegate.task = streamTask
            streamTask.resume()

            continuation.onTermination = { _ in
                streamTask.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    private func streamOpenAI(apiKey: String, config: AIConfig, messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        let request = buildOpenAIRequest(config: config, apiKey: apiKey, messages: messages, stream: true)
        return AsyncThrowingStream { continuation in
            let delegate = SSEDelegate(
                onComplete: { continuation.finish() },
                onError: { continuation.finish(throwing: $0) }
            )
            delegate.onEvent = { _, data in
                guard data != "[DONE]" else {
                    continuation.finish()
                    return
                }
                guard let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let text = delta["content"] as? String else { return }
                continuation.yield(text)
            }

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let streamTask = session.dataTask(with: request)
            delegate.task = streamTask
            streamTask.resume()

            continuation.onTermination = { _ in
                streamTask.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    // MARK: - Request Builders

    private func buildClaudeRequest(config: AIConfig, apiKey: String, system: String, messages: [[String: String]], stream: Bool) -> URLRequest {
        let url = URL(string: "\(config.effectiveBaseURL)/v1/messages")!
        log.info(mod, "调用 Claude API: \(url.absoluteString), 模型: \(config.effectiveModel), stream: \(stream)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": 2048,
            "system": system,
            "messages": messages,
        ]
        if stream { body["stream"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildOpenAIRequest(config: AIConfig, apiKey: String, messages: [[String: String]], stream: Bool) -> URLRequest {
        let url = URL(string: "\(config.effectiveBaseURL)/v1/chat/completions")!
        log.info(mod, "调用 OpenAI API: \(url.absoluteString), 模型: \(config.effectiveModel), stream: \(stream)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": 2048,
            "messages": messages,
        ]
        if stream { body["stream"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - SSE Delegate

/// URLSession delegate 用于解析 Server-Sent Events 流
private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var currentBlockType: String = "text"
    var task: URLSessionDataTask?
    var onEvent: ((_ event: String?, _ data: String) -> Void)?

    private let onComplete: () -> Void
    private let onError: (Error) -> Void
    private var buffer = ""

    init(onComplete: @escaping () -> Void,
         onError: @escaping (Error) -> Void) {
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let error = NSError(domain: "AIService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            onError(error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            onError(error)
        } else {
            // 处理剩余 buffer
            if !buffer.isEmpty { processBuffer() }
            onComplete()
        }
    }

    private func processBuffer() {
        // SSE 格式: "event: xxx\ndata: yyy\n\n"
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            var event: String?
            var dataLines: [String] = []

            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("event:") {
                    event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }

            if !dataLines.isEmpty {
                let data = dataLines.joined(separator: "\n")
                onEvent?(event, data)
            }
        }
    }
}
