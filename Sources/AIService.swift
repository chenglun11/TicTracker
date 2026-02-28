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

    var effectivePrompt: String {
        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPrompt : trimmed
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

    private let keychainService = "com.tictracker.ai"
    private let keychainAccount = "api-key"
    private let keychainBaseURLAccount = "base-url"
    private let keychainModelAccount = "model"

    struct StoredConfig {
        var apiKey: String
        var baseURL: String
        var model: String
    }

    func loadAll() -> StoredConfig {
        let all = KeychainHelper.loadAll(service: keychainService)
        return StoredConfig(
            apiKey: all[keychainAccount].flatMap { String(data: $0, encoding: .utf8) } ?? "",
            baseURL: all[keychainBaseURLAccount].flatMap { String(data: $0, encoding: .utf8) } ?? "",
            model: all[keychainModelAccount].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        )
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
    }

    private func save(_ account: String, value: String) {
        if let data = value.data(using: .utf8) {
            KeychainHelper.save(service: keychainService, account: account, data: data)
        }
    }

    private func load(_ account: String) -> String? {
        guard let data = KeychainHelper.load(service: keychainService, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
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
        guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let systemPrompt = config.effectivePrompt
        let userPrompt = "以下是本周的原始技术支持数据，请生成周报摘要：\n\n\(rawReport)"

        switch config.provider {
        case .claude: return try await callClaude(apiKey: apiKey, config: config, system: systemPrompt, user: userPrompt)
        case .openai: return try await callOpenAI(apiKey: apiKey, config: config, system: systemPrompt, user: userPrompt)
        }
    }

    // MARK: - Claude API

    private func callClaude(apiKey: String, config: AIConfig, system: String, user: String) async throws -> String {
        let url = URL(string: "\(config.effectiveBaseURL)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIError.requestFailed("Claude API 错误: \(msg)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIError.invalidResponse
        }
        return text
    }

    // MARK: - OpenAI API

    private func callOpenAI(apiKey: String, config: AIConfig, system: String, user: String) async throws -> String {
        let url = URL(string: "\(config.effectiveBaseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": config.effectiveModel,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
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
}
