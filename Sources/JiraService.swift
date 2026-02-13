import Foundation

enum JiraError: Sendable {
    case success
    case authError
    case networkError(String)
    case parseError
}

@MainActor
final class JiraService {
    static let shared = JiraService()
    private var pollingTask: Task<Void, Never>?
    private var store: DataStore?

    private init() {}

    func setup(store: DataStore) {
        self.store = store
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard let store, store.jiraConfig.enabled else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                await fetchMyIssues()
                let minutes = store.jiraConfig.pollingInterval
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func restartPolling() {
        stopPolling()
        startPolling()
    }

    // MARK: - API

    func fetchMyIssues() async {
        guard let store else { return }
        let config = store.jiraConfig
        guard !config.serverURL.isEmpty, !config.username.isEmpty else { return }
        guard let token = loadToken(), !token.isEmpty else { return }

        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(base)/rest/api/2/search") else { return }
        components.queryItems = [
            URLQueryItem(name: "jql", value: config.jql),
            URLQueryItem(name: "fields", value: "summary,status,priority,issuetype"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let issues = parseIssues(data)
            store.jiraIssues = issues
        } catch {
            DevLog.shared.error("Jira", "fetchMyIssues failed: \(error.localizedDescription)")
        }
    }

    func fetchTransitions(issueKey: String) async -> [JiraTransition] {
        guard let store else { return [] }
        let config = store.jiraConfig
        guard let token = loadToken() else { return [] }
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/rest/api/2/issue/\(issueKey)/transitions") else { return [] }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return parseTransitions(data)
        } catch {
            return []
        }
    }

    func doTransition(issueKey: String, transitionID: String) async -> Bool {
        guard let store else { return false }
        let config = store.jiraConfig
        guard let token = loadToken() else { return false }
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/rest/api/2/issue/\(issueKey)/transitions") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, username: config.username, token: token)
        let body: [String: Any] = ["transition": ["id": transitionID]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 204 || http.statusCode == 200
        } catch {
            return false
        }
    }

    func testConnection() async -> JiraError {
        guard let store else { return .networkError("未初始化") }
        let config = store.jiraConfig
        guard !config.serverURL.isEmpty else { return .networkError("服务器地址为空") }
        guard !config.username.isEmpty else { return .authError }
        guard let token = loadToken(), !token.isEmpty else { return .authError }

        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/rest/api/2/myself") else { return .networkError("URL 无效") }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .networkError("无响应") }
            switch http.statusCode {
            case 200: return .success
            case 401, 403: return .authError
            default: return .networkError("HTTP \(http.statusCode)")
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func loadToken() -> String? {
        guard let data = KeychainHelper.load() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func applyAuth(_ request: inout URLRequest, username: String, token: String) {
        let cred = "\(username):\(token)"
        if let data = cred.data(using: .utf8) {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }

    private nonisolated func parseIssues(_ data: Data) -> [JiraIssue] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = json["issues"] as? [[String: Any]] else { return [] }
        return issues.compactMap { issue -> JiraIssue? in
            guard let key = issue["key"] as? String,
                  let fields = issue["fields"] as? [String: Any],
                  let summary = fields["summary"] as? String else { return nil }
            let statusObj = fields["status"] as? [String: Any]
            let statusName = statusObj?["name"] as? String ?? "Unknown"
            let statusCategory = statusObj?["statusCategory"] as? [String: Any]
            let categoryKey = statusCategory?["key"] as? String ?? "undefined"
            let priorityObj = fields["priority"] as? [String: Any]
            let priorityName = priorityObj?["name"] as? String
            let typeObj = fields["issuetype"] as? [String: Any]
            let typeName = typeObj?["name"] as? String
            return JiraIssue(key: key, summary: summary, status: statusName,
                             statusCategoryKey: categoryKey, priority: priorityName, issueType: typeName)
        }
    }

    private nonisolated func parseTransitions(_ data: Data) -> [JiraTransition] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitions = json["transitions"] as? [[String: Any]] else { return [] }
        return transitions.compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            return JiraTransition(id: id, name: name)
        }
    }
}
