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
                if isInPollingWindow(config: store.jiraConfig) {
                    _ = await fetchByMode()
                    await syncTrackedIssues()
                }
                let minutes = store.jiraConfig.pollingInterval
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    private func isInPollingWindow(config: JiraConfig) -> Bool {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let minute = Calendar.current.component(.minute, from: now)
        let current = hour * 60 + minute
        let start = config.pollingStartHour * 60 + config.pollingStartMinute
        let end = config.pollingEndHour * 60 + config.pollingEndMinute
        return current >= start && current < end
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

    /// Fetch issues based on current jiraSourceMode setting
    func fetchByMode() async -> String? {
        guard let store else { return "未初始化" }
        let mode = store.jiraSourceMode
        var error: String?
        if mode == 0 || mode == 2 { error = await fetchMyIssues() }
        if mode == 1 || mode == 2 { error = await fetchReportedIssues() ?? error }
        return error
    }

    func fetchMyIssues() async -> String? {
        guard let store else { return "未初始化" }
        let config = store.jiraConfig
        guard !config.serverURL.isEmpty else { return "请先配置服务器地址" }
        if config.authMode == .password, config.username.isEmpty { return "请先配置用户名" }
        guard let token = loadToken(), !token.isEmpty else { return "密码 / Token 未设置" }

        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(base)/rest/api/2/search") else { return "URL 无效" }
        components.queryItems = [
            URLQueryItem(name: "jql", value: config.jql),
            URLQueryItem(name: "fields", value: "summary,status,priority,issuetype,assignee"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        guard let url = components.url else { return "URL 无效" }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "无响应" }
            guard http.statusCode == 200 else {
                return http.statusCode == 401 ? "认证失败" : "HTTP \(http.statusCode)"
            }
            let issues = parseIssues(data)
            store.jiraIssues = issues
            return nil
        } catch {
            DevLog.shared.error("Jira", "fetchMyIssues failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func fetchReportedIssues() async -> String? {
        guard let store else { return "未初始化" }
        let config = store.jiraConfig
        guard !config.serverURL.isEmpty else { return "请先配置服务器地址" }
        if config.authMode == .password, config.username.isEmpty { return "请先配置用户名" }
        guard let token = loadToken(), !token.isEmpty else { return "密码 / Token 未设置" }

        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(base)/rest/api/2/search") else { return "URL 无效" }
        let jql = "reporter=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
        components.queryItems = [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: "summary,status,priority,issuetype,assignee"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        guard let url = components.url else { return "URL 无效" }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "无响应" }
            guard http.statusCode == 200 else {
                return http.statusCode == 401 ? "认证失败" : "HTTP \(http.statusCode)"
            }
            let issues = parseIssues(data)
            store.reportedJiraIssues = issues
            return nil
        } catch {
            DevLog.shared.error("Jira", "fetchReportedIssues failed: \(error.localizedDescription)")
            return error.localizedDescription
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
        if config.authMode == .password, config.username.isEmpty { return .authError }
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

    // MARK: - Sync Tracked Issues with Jira Status & Comments

    /// Syncs local TrackedIssues that have a jiraKey with the latest Jira status and comments.
    func syncTrackedIssues() async {
        guard let store else { return }
        // Merge assigned + reported for broader lookup
        var jiraMap: [String: JiraIssue] = [:]
        for issue in store.jiraIssues { jiraMap[issue.key] = issue }
        for issue in store.reportedJiraIssues { jiraMap[issue.key] = jiraMap[issue.key] ?? issue }

        // Only sync comments for issues updated in the last 7 days to avoid N+1 on every poll
        let commentCutoff = Date().addingTimeInterval(-7 * 24 * 3600)

        for issue in store.trackedIssues {
            guard let rawKey = issue.jiraKey, !rawKey.isEmpty else { continue }

            // Extract issue key from URL if needed (e.g. "https://jira.example.com/browse/YC-123" → "YC-123")
            let jiraKey: String
            if rawKey.hasPrefix("http"), let url = URL(string: rawKey.trimmingCharacters(in: .whitespacesAndNewlines)),
               let last = url.pathComponents.last, last.contains("-") {
                jiraKey = last
            } else {
                jiraKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !jiraKey.isEmpty else { continue }

            // If not in batch results, fetch individually
            var jiraIssue = jiraMap[jiraKey]
            if jiraIssue == nil {
                jiraIssue = await fetchSingleIssue(key: jiraKey)
                if jiraIssue == nil {
                    DevLog.shared.info("JiraSync", "\(jiraKey) fetch failed, skipped")
                    continue
                }
            }

            guard let ji = jiraIssue else { continue }

            // --- Status sync ---
            let newStatus = mapJiraStatus(ji.statusCategoryKey, statusName: ji.status)
            if newStatus != issue.status && issue.status != .observing {
                // 如果有开发活动且 Jira 想改回"待处理"，跳过（GitLab 活动优先）
                let skipDowngrade = issue.hasDevActivity && newStatus == .pending && issue.status == .inProgress
                if !skipDowngrade {
                    let oldLabel = issue.status.rawValue
                    let newLabel = newStatus.rawValue
                    let commentText = "[Jira] 状态变更: \(oldLabel) → \(newLabel)（\(ji.status)）"
                    let alreadyLogged = issue.comments.contains { $0.text == commentText }
                    if !alreadyLogged {
                        store.updateIssueStatus(id: issue.id, status: newStatus)
                        store.addIssueComment(id: issue.id, text: commentText)
                        DevLog.shared.info("JiraSync", "\(jiraKey): \(oldLabel) → \(newLabel)")
                    }
                }
            }

            // --- Assignee sync ---
            if let jiraAssignee = ji.assignee, !jiraAssignee.isEmpty {
                if issue.assignee != jiraAssignee {
                    let oldAssignee = issue.assignee ?? "未指派"
                    let commentText = "[Jira] 经办人变更: \(oldAssignee) → \(jiraAssignee)"
                    let alreadyLogged = issue.comments.contains { $0.text == commentText }
                    if !alreadyLogged {
                        store.updateIssueAssignee(id: issue.id, assignee: jiraAssignee)
                        store.addIssueComment(id: issue.id, text: commentText)
                        DevLog.shared.info("JiraSync", "\(jiraKey): assignee \(oldAssignee) → \(jiraAssignee)")
                    }
                }
            } else if issue.assignee != nil {
                let oldAssignee = issue.assignee!
                let commentText = "[Jira] 经办人变更: \(oldAssignee) → 未指派"
                let alreadyLogged = issue.comments.contains { $0.text == commentText }
                if !alreadyLogged {
                    store.updateIssueAssignee(id: issue.id, assignee: nil)
                    store.addIssueComment(id: issue.id, text: commentText)
                    DevLog.shared.info("JiraSync", "\(jiraKey): assignee \(oldAssignee) → unassigned")
                }
            }

            // --- Comment sync (only for recently active issues) ---
            guard (issue.updatedAt ?? issue.createdAt) >= commentCutoff else { continue }
            let remoteComments = await fetchJiraComments(issueKey: jiraKey)
            // Build from current store snapshot to include any comments added earlier this loop
            let freshIssue = store.trackedIssues.first { $0.id == issue.id }
            let existingJiraIds = Set((freshIssue ?? issue).comments.compactMap { $0.jiraCommentId })
            for rc in remoteComments {
                guard !existingJiraIds.contains(rc.id) else { continue }
                let comment = IssueComment(
                    text: "[Jira] \(rc.author): \(rc.body)",
                    createdAt: rc.created,
                    jiraCommentId: rc.id
                )
                store.addIssueCommentDirect(id: issue.id, comment: comment)
                DevLog.shared.info("JiraSync", "\(jiraKey): synced comment \(rc.id)")
            }

            // 检测所有远程评论中是否有 GitLab bot 活动
            let hasGitActivity = remoteComments.contains { rc in
                let a = rc.author.lowercased()
                return a.contains("gitlab") || a.contains("git")
            }
            if hasGitActivity {
                let current = store.trackedIssues.first { $0.id == issue.id }
                if current?.hasDevActivity != true {
                    store.markDevActivity(id: issue.id)
                    DevLog.shared.info("JiraSync", "\(jiraKey): 检测到开发活动")
                }
                if current?.status == .pending {
                    store.updateIssueStatus(id: issue.id, status: .inProgress)
                    DevLog.shared.info("JiraSync", "\(jiraKey): 自动变更为处理中 (GitLab 活动)")
                }
            }
        }
    }

    private func mapJiraStatus(_ categoryKey: String, statusName: String = "") -> IssueStatus {
        // 优先使用自定义状态映射（按 Jira 状态名匹配）
        if !statusName.isEmpty, let store {
            for (jiraName, localCase) in store.jiraConfig.statusMapping {
                if jiraName.localizedCaseInsensitiveCompare(statusName) == .orderedSame,
                   let matched = IssueStatus.fromCaseName(localCase) {
                    return matched
                }
            }
        }
        // Fallback: 按 Jira statusCategoryKey 映射
        switch categoryKey {
        case "new": return .pending
        case "indeterminate": return .inProgress
        case "done": return .fixed
        default: return .pending
        }
    }

    // MARK: - Helpers

    /// Fetch a single Jira issue by key (for issues not in JQL batch results)
    private func fetchSingleIssue(key: String) async -> JiraIssue? {
        guard let store else { return nil }
        let config = store.jiraConfig
        guard let token = loadToken() else { return nil }
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/rest/api/2/issue/\(key)?fields=summary,status,priority,issuetype,assignee") else { return nil }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parseSingleIssue(data)
        } catch {
            DevLog.shared.error("Jira", "fetchSingleIssue(\(key)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated func parseSingleIssue(_ data: Data) -> JiraIssue? {
        guard let issue = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = issue["key"] as? String,
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
        let assigneeObj = fields["assignee"] as? [String: Any]
        let assigneeName = assigneeObj?["displayName"] as? String
        return JiraIssue(key: key, summary: summary, status: statusName,
                         statusCategoryKey: categoryKey, priority: priorityName, issueType: typeName, assignee: assigneeName)
    }

    struct JiraCommentEntry: Sendable {
        let id: String
        let author: String
        let body: String
        let created: Date
    }

    /// Fetch comments for a Jira issue
    private func fetchJiraComments(issueKey: String) async -> [JiraCommentEntry] {
        guard let store else { return [] }
        let config = store.jiraConfig
        guard let token = loadToken() else { return [] }
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/rest/api/2/issue/\(issueKey)/comment?orderBy=-created&maxResults=20") else { return [] }

        var request = URLRequest(url: url)
        applyAuth(&request, username: config.username, token: token)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return parseJiraComments(data)
        } catch {
            DevLog.shared.error("Jira", "fetchJiraComments(\(issueKey)) failed: \(error.localizedDescription)")
            return []
        }
    }

    private nonisolated func parseJiraComments(_ data: Data) -> [JiraCommentEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let comments = json["comments"] as? [[String: Any]] else { return [] }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return comments.compactMap { c in
            guard let id = c["id"] as? String,
                  let bodyObj = c["body"] else { return nil }
            let body: String
            if let bodyStr = bodyObj as? String {
                body = bodyStr
            } else if let bodyDoc = bodyObj as? [String: Any] {
                // Jira Cloud uses ADF (Atlassian Document Format)
                body = Self.extractTextFromADF(bodyDoc)
            } else {
                return nil
            }
            let authorObj = c["author"] as? [String: Any]
            let author = authorObj?["displayName"] as? String ?? "未知"
            let createdStr = c["created"] as? String ?? ""
            let created = fmt.date(from: createdStr) ?? Date()
            return JiraCommentEntry(id: id, author: author, body: body, created: created)
        }
    }

    /// Extract plain text from Atlassian Document Format (ADF) used by Jira Cloud
    private nonisolated static func extractTextFromADF(_ doc: [String: Any]) -> String {
        guard let content = doc["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { node -> String? in
            if let innerContent = node["content"] as? [[String: Any]] {
                return innerContent.compactMap { inner -> String? in
                    inner["text"] as? String
                }.joined()
            }
            return nil
        }.joined(separator: "\n")
    }

    private func loadToken() -> String? {
        guard let data = KeychainHelper.load() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func applyAuth(_ request: inout URLRequest, username: String, token: String) {
        guard let store else { return }
        switch store.jiraConfig.authMode {
        case .password:
            let cred = "\(username):\(token)"
            if let data = cred.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        case .pat:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            let assigneeObj = fields["assignee"] as? [String: Any]
            let assigneeName = assigneeObj?["displayName"] as? String
            return JiraIssue(key: key, summary: summary, status: statusName,
                             statusCategoryKey: categoryKey, priority: priorityName, issueType: typeName, assignee: assigneeName)
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
