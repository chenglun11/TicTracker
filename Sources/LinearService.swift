import Foundation

@MainActor
@Observable
final class LinearService {
    static let shared = LinearService()
    private var store: DataStore?
    private var pollingTask: Task<Void, Never>?

    private init() {}

    func setup(store: DataStore) {
        self.store = store
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard let store, store.linearConfig.enabled else { return }
        pollingTask = Task {
            while !Task.isCancelled {
                if isInPollingWindow() {
                    await syncTrackedIssues()
                }
                let minutes = store.linearConfig.pollingInterval
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

    private func isInPollingWindow() -> Bool {
        guard let store else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= store.linearConfig.pollingStartHour && hour < store.linearConfig.pollingEndHour
    }

    // MARK: - API

    func testConnection() async -> LinearError {
        guard let token = loadToken(), !token.isEmpty else { return .unauthorized }
        let query = #"{"query":"{ viewer { id name } }"}"#
        do {
            let (data, response) = try await performRequest(query: query, token: token)
            guard let http = response as? HTTPURLResponse else { return .networkError }
            let statusError = classifyHTTPStatus(http.statusCode)
            if statusError != .ok {
                let body = String(data: data, encoding: .utf8) ?? "(no body)"
                DevLog.shared.error("Linear", "testConnection HTTP \(http.statusCode): \(body)")
                return statusError
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DevLog.shared.error("Linear", "testConnection: invalid JSON response")
                return .unknown
            }
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = (errors.first?["message"] as? String) ?? "unknown GraphQL error"
                DevLog.shared.error("Linear", "testConnection: \(msg)")
                if msg.contains("authentication") || msg.contains("unauthorized") {
                    return .unauthorized
                }
                return .unknown
            }
            if let data = json["data"] as? [String: Any], data["viewer"] != nil {
                DevLog.shared.info("Linear", "testConnection: success")
                return .ok
            }
            DevLog.shared.error("Linear", "testConnection: no viewer in response")
            return .unknown
        } catch {
            DevLog.shared.error("Linear", "testConnection: \(error.localizedDescription)")
            return .networkError
        }
    }

    func fetchTeams() async -> [LinearTeam] {
        guard let token = loadToken() else { return [] }
        let query = #"{"query":"{ teams { nodes { id name key } } }"}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let teams = data["teams"] as? [String: Any],
              let nodes = teams["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseTeam($0) }
    }

    func fetchProjects(teamId: String) async -> [LinearProject] {
        guard let token = loadToken() else { return [] }
        let q = "{ team(id: \\\"\(teamId)\\\") { projects { nodes { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let team = data["team"] as? [String: Any],
              let projects = team["projects"] as? [String: Any],
              let nodes = projects["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            return LinearProject(id: id, name: name)
        }
    }

    func fetchTeamStates(teamId: String) async -> [LinearState] {
        guard let token = loadToken() else { return [] }
        let q = "{ team(id: \\\"\(teamId)\\\") { states { nodes { id name type } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let team = data["team"] as? [String: Any],
              let states = team["states"] as? [String: Any],
              let nodes = states["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseState($0) }
    }

    func createIssue(title: String, description: String?, teamId: String, projectId: String?, assigneeId: String?) async -> LinearIssue? {
        guard let token = loadToken() else { return nil }
        var inputFields = "title: \\\"\(escapeGraphQL(title))\\\", teamId: \\\"\(teamId)\\\""
        if let desc = description, !desc.isEmpty {
            inputFields += ", description: \\\"\(escapeGraphQL(desc))\\\""
        }
        if let pid = projectId, !pid.isEmpty {
            inputFields += ", projectId: \\\"\(pid)\\\""
        }
        let effectiveAssigneeId = assigneeId ?? {
            let defaultId = store?.linearConfig.defaultAssigneeId ?? ""
            return defaultId.isEmpty ? nil : defaultId
        }()
        if let aid = effectiveAssigneeId, !aid.isEmpty {
            inputFields += ", assigneeId: \\\"\(aid)\\\""
        }
        let q = "mutation { issueCreate(input: { \(inputFields) }) { success issue { id identifier title url } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let issueCreate = data["issueCreate"] as? [String: Any],
              let success = issueCreate["success"] as? Bool, success,
              let issue = issueCreate["issue"] as? [String: Any] else { return nil }
        guard let id = issue["id"] as? String,
              let identifier = issue["identifier"] as? String,
              let issueTitle = issue["title"] as? String,
              let url = issue["url"] as? String else { return nil }
        return LinearIssue(id: id, identifier: identifier, title: issueTitle, url: url)
    }

    func updateIssueState(issueId: String, stateId: String) async -> Bool {
        guard let token = loadToken() else { return false }
        let q = "mutation { issueUpdate(id: \\\"\(issueId)\\\", input: { stateId: \\\"\(stateId)\\\" }) { success } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return false }
        guard let data = json["data"] as? [String: Any],
              let issueUpdate = data["issueUpdate"] as? [String: Any],
              let success = issueUpdate["success"] as? Bool else { return false }
        return success
    }

    func addComment(issueId: String, body: String) async -> Bool {
        guard let token = loadToken() else { return false }
        let q = "mutation { commentCreate(input: { issueId: \\\"\(issueId)\\\", body: \\\"\(escapeGraphQL(body))\\\" }) { success } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return false }
        guard let data = json["data"] as? [String: Any],
              let commentCreate = data["commentCreate"] as? [String: Any],
              let success = commentCreate["success"] as? Bool else { return false }
        return success
    }

    func fetchIssueComments(issueId: String) async -> [LinearComment] {
        guard let token = loadToken() else { return [] }
        let q = "{ issue(id: \\\"\(issueId)\\\") { comments { nodes { id body createdAt user { id name } } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let issue = data["issue"] as? [String: Any],
              let comments = issue["comments"] as? [String: Any],
              let nodes = comments["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseComment($0) }
    }

    func fetchIssueDetail(issueId: String) async -> LinearIssue? {
        guard let token = loadToken() else { return nil }
        let q = "{ issue(id: \\\"\(issueId)\\\") { id identifier title description url state { id name type } assignee { id name } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let issue = data["issue"] as? [String: Any] else { return nil }
        return parseIssueDetail(issue)
    }

    func fetchMyIssues(teamId: String? = nil, projectId: String? = nil) async -> [LinearIssue] {
        guard let token = loadToken() else { return [] }
        var filter = "assignee: { isMe: { eq: true } }"
        if let tid = teamId, !tid.isEmpty {
            filter += ", team: { id: { eq: \\\"\(tid)\\\" } }"
        }
        if let pid = projectId, !pid.isEmpty {
            filter += ", project: { id: { eq: \\\"\(pid)\\\" } }"
        }
        let q = "{ issues(filter: { \(filter) }, first: 50, orderBy: updatedAt) { nodes { id identifier title description url state { id name type } assignee { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let issues = data["issues"] as? [String: Any],
              let nodes = issues["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseIssueDetail($0) }
    }

    func searchIssues(query searchText: String, teamId: String? = nil) async -> [LinearIssue] {
        guard let token = loadToken() else { return [] }
        var filterArg = ""
        if let tid = teamId, !tid.isEmpty {
            filterArg = ", filter: { team: { id: { eq: \\\"\(tid)\\\" } } }"
        }
        let q = "{ issueSearch(query: \\\"\(escapeGraphQL(searchText))\\\"\(filterArg), first: 30) { nodes { id identifier title description url state { id name type } assignee { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let issueSearch = data["issueSearch"] as? [String: Any],
              let nodes = issueSearch["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parseIssueDetail($0) }
    }

    // MARK: - Sync

    func syncTrackedIssues() async {
        guard let store else { return }
        for issue in store.trackedIssues {
            guard let linearId = issue.linearIssueId, !linearId.isEmpty else { continue }
            guard let detail = await fetchIssueDetail(issueId: linearId) else {
                DevLog.shared.info("LinearSync", "\(issue.linearKey ?? linearId) fetch failed, skipped")
                continue
            }

            // Status sync
            if let state = detail.state {
                let newStatus = mapLinearState(state.name)
                if let newStatus, newStatus != issue.status {
                    let oldLabel = issue.status.rawValue
                    let newLabel = newStatus.rawValue
                    let commentText = "[Linear] 状态变更: \(oldLabel) → \(newLabel)（\(state.name)）"
                    let alreadyLogged = issue.comments.contains { $0.text == commentText }
                    if !alreadyLogged {
                        store.updateIssueStatus(id: issue.id, status: newStatus)
                        store.addIssueComment(id: issue.id, text: commentText)
                        DevLog.shared.info("LinearSync", "\(issue.linearKey ?? linearId): \(oldLabel) → \(newLabel)")
                    }
                }
            }

            // Assignee sync
            let remoteAssignee = detail.assignee?.name
            let localAssignee = issue.linearAssignee
            if remoteAssignee != localAssignee {
                let oldName = localAssignee ?? "无"
                let newName = remoteAssignee ?? "无"
                let commentText = "[Linear] 负责人变更: \(oldName) → \(newName)"
                let alreadyLogged = issue.comments.contains { $0.text == commentText }
                if !alreadyLogged {
                    store.updateIssueLinearAssignee(id: issue.id, assignee: remoteAssignee)
                    store.addIssueComment(id: issue.id, text: commentText)
                    DevLog.shared.info("LinearSync", "\(issue.linearKey ?? linearId): assignee \(oldName) → \(newName)")
                }
            }

            // Comment sync
            let remoteComments = await fetchIssueComments(issueId: linearId)
            let freshIssue = store.trackedIssues.first { $0.id == issue.id }
            let existingLinearIds = Set((freshIssue ?? issue).comments.compactMap { c -> String? in
                guard c.jiraCommentId?.hasPrefix("linear:") == true else { return nil }
                return c.jiraCommentId
            })
            for rc in remoteComments {
                let linearCommentId = "linear:\(rc.id)"
                guard !existingLinearIds.contains(linearCommentId) else { continue }
                let authorName = rc.user?.name ?? "未知"
                let comment = IssueComment(
                    text: "[Linear] \(authorName): \(rc.body)",
                    createdAt: parseISO8601(rc.createdAt) ?? Date(),
                    jiraCommentId: linearCommentId
                )
                store.addIssueCommentDirect(id: issue.id, comment: comment)
                DevLog.shared.info("LinearSync", "\(issue.linearKey ?? linearId): synced comment \(rc.id)")
            }
        }
    }

    // MARK: - Private Helpers

    private func loadToken() -> String? {
        guard let data = KeychainHelper.load(
            service: KeychainHelper.service,
            account: LinearConfig.keychainTokenKey
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func performRequest(query: String, token: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: "https://api.linear.app/graphql") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = query.data(using: .utf8)
        return try await URLSession.shared.data(for: request)
    }

    private func executeQuery(query: String, token: String) async -> [String: Any]? {
        do {
            let (data, response) = try await performRequest(query: query, token: token)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = response as? HTTPURLResponse {
                    DevLog.shared.error("Linear", "HTTP \(http.statusCode)")
                }
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            DevLog.shared.error("Linear", "request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func classifyHTTPStatus(_ code: Int) -> LinearError {
        switch code {
        case 200: return .ok
        case 401: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .unknown
        }
    }

    private func mapLinearState(_ stateName: String) -> IssueStatus? {
        guard let store else { return nil }
        for (linearName, localCase) in store.linearConfig.statusMapping {
            if linearName.localizedCaseInsensitiveCompare(stateName) == .orderedSame,
               let matched = IssueStatus.fromCaseName(localCase) {
                return matched
            }
        }
        return nil
    }

    private func escapeGraphQL(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: str)
    }

    // MARK: - JSON Parsing

    private nonisolated func parseTeam(_ node: [String: Any]) -> LinearTeam? {
        guard let id = node["id"] as? String,
              let name = node["name"] as? String,
              let key = node["key"] as? String else { return nil }
        return LinearTeam(id: id, name: name, key: key)
    }

    private nonisolated func parseState(_ node: [String: Any]) -> LinearState? {
        guard let id = node["id"] as? String,
              let name = node["name"] as? String,
              let type = node["type"] as? String else { return nil }
        return LinearState(id: id, name: name, type: type)
    }

    private nonisolated func parseComment(_ node: [String: Any]) -> LinearComment? {
        guard let id = node["id"] as? String,
              let body = node["body"] as? String else { return nil }
        let createdAt = node["createdAt"] as? String
        var user: LinearUser?
        if let userObj = node["user"] as? [String: Any],
           let uid = userObj["id"] as? String,
           let uname = userObj["name"] as? String {
            user = LinearUser(id: uid, name: uname)
        }
        return LinearComment(id: id, body: body, createdAt: createdAt, user: user)
    }

    private nonisolated func parseIssueDetail(_ node: [String: Any]) -> LinearIssue? {
        guard let id = node["id"] as? String,
              let identifier = node["identifier"] as? String,
              let title = node["title"] as? String,
              let url = node["url"] as? String else { return nil }
        let description = node["description"] as? String
        var state: LinearState?
        if let stateObj = node["state"] as? [String: Any] {
            state = parseState(stateObj)
        }
        var assignee: LinearUser?
        if let assigneeObj = node["assignee"] as? [String: Any],
           let aid = assigneeObj["id"] as? String,
           let aname = assigneeObj["name"] as? String {
            assignee = LinearUser(id: aid, name: aname)
        }
        return LinearIssue(id: id, identifier: identifier, title: title, description: description,
                           state: state, assignee: assignee, url: url)
    }
}
