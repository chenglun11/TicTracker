import Foundation

@MainActor
@Observable
final class LinearService {
    static let shared = LinearService()
    private var store: DataStore?
    private var pollingTask: Task<Void, Never>?
    private var isSyncing = false

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
                let minutes = max(store.linearConfig.pollingInterval, 1)
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

    func fetchTeamMembers(teamId: String) async -> [LinearUser] {
        guard let token = loadToken() else { return [] }
        let q = "{ viewer { id name } team(id: \\\"\(escapeGraphQL(teamId))\\\") { members(first: 100) { nodes { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let team = data["team"] as? [String: Any],
              let members = team["members"] as? [String: Any],
              let nodes = members["nodes"] as? [[String: Any]] else { return [] }
        var result = nodes.compactMap { node -> LinearUser? in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            return LinearUser(id: id, name: name)
        }
        // Ensure the current API user (viewer) is always included
        if let viewer = data["viewer"] as? [String: Any],
           let viewerId = viewer["id"] as? String,
           let viewerName = viewer["name"] as? String,
           !result.contains(where: { $0.id == viewerId }) {
            result.insert(LinearUser(id: viewerId, name: viewerName), at: 0)
        }
        DevLog.shared.info("Linear", "fetchTeamMembers: team=\(teamId), count=\(result.count), names=\(result.map(\.name).joined(separator: ", "))")
        return result
    }

    func fetchTeamLabels(teamId: String) async -> [LinearLabel] {
        guard let token = loadToken() else { return [] }
        let q = "{ team(id: \\\"\(escapeGraphQL(teamId))\\\") { labels { nodes { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return [] }
        guard let data = json["data"] as? [String: Any],
              let team = data["team"] as? [String: Any],
              let labels = team["labels"] as? [String: Any],
              let nodes = labels["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
            return LinearLabel(id: id, name: name)
        }
    }

    func createIssue(title: String, description: String?, teamId: String, projectId: String?, assigneeId: String?, labelIds: [String]? = nil) async -> LinearIssue? {
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
        if let ids = labelIds, !ids.isEmpty {
            let quoted = ids.map { "\\\"\($0)\\\"" }.joined(separator: ", ")
            inputFields += ", labelIds: [\(quoted)]"
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

    /// Resolve a state name to its ID using cached team states, then push.
    @discardableResult
    func updateIssueStateByName(issueId: String, stateName: String) async -> Bool {
        guard let store else { return false }
        let teamId = store.linearConfig.teamId
        guard !teamId.isEmpty else { return false }
        let states = await fetchTeamStates(teamId: teamId)
        guard let target = states.first(where: { $0.name.localizedCaseInsensitiveCompare(stateName) == .orderedSame }) else {
            DevLog.shared.info("Linear", "pushStatus: state '\(stateName)' not found in team states")
            return false
        }
        let ok = await updateIssueState(issueId: issueId, stateId: target.id)
        if ok {
            DevLog.shared.info("Linear", "pushStatus: \(issueId) → \(stateName) (\(target.id))")
        } else {
            DevLog.shared.error("Linear", "pushStatus failed: \(issueId) → \(stateName)")
        }
        return ok
    }

    /// Push assignee to Linear. Pass nil/empty assigneeId to unassign.
    func updateIssueAssignee(issueId: String, assigneeId: String?) async -> Bool {
        guard let token = loadToken() else { return false }
        let value: String
        if let aid = assigneeId, !aid.isEmpty {
            value = "\\\"\(escapeGraphQL(aid))\\\""
        } else {
            value = "null"
        }
        let q = "mutation { issueUpdate(id: \\\"\(escapeGraphQL(issueId))\\\", input: { assigneeId: \(value) }) { success } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else {
            DevLog.shared.error("Linear", "updateIssueAssignee: query failed")
            return false
        }
        guard let data = json["data"] as? [String: Any],
              let issueUpdate = data["issueUpdate"] as? [String: Any],
              let success = issueUpdate["success"] as? Bool else {
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                DevLog.shared.error("Linear", "updateIssueAssignee errors: \(msg)")
            }
            return false
        }
        return success
    }

    /// Push project to Linear. Pass nil/empty projectId to clear project.
    func updateIssueProject(issueId: String, projectId: String?) async -> Bool {
        guard let token = loadToken() else { return false }
        let value: String
        if let projectId, !projectId.isEmpty {
            value = "\\\"\(escapeGraphQL(projectId))\\\""
        } else {
            value = "null"
        }
        let q = "mutation { issueUpdate(id: \\\"\(escapeGraphQL(issueId))\\\", input: { projectId: \(value) }) { success } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else {
            DevLog.shared.error("Linear", "updateIssueProject: query failed")
            return false
        }
        guard let data = json["data"] as? [String: Any],
              let issueUpdate = data["issueUpdate"] as? [String: Any],
              let success = issueUpdate["success"] as? Bool else {
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                DevLog.shared.error("Linear", "updateIssueProject errors: \(msg)")
            }
            return false
        }
        return success
    }

    @discardableResult
    func updateIssueTitle(issueId: String, title: String) async -> Bool {
        guard let token = loadToken() else { return false }
        let q = "mutation { issueUpdate(id: \\\"\(escapeGraphQL(issueId))\\\", input: { title: \\\"\(escapeGraphQL(title))\\\" }) { success } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return false }
        guard let data = json["data"] as? [String: Any],
              let issueUpdate = data["issueUpdate"] as? [String: Any],
              let success = issueUpdate["success"] as? Bool else { return false }
        return success
    }

    @discardableResult
    func addComment(issueId: String, body: String) async -> LinearComment? {
        guard let token = loadToken() else { return nil }
        let q = "mutation { commentCreate(input: { issueId: \\\"\(escapeGraphQL(issueId))\\\", body: \\\"\(escapeGraphQL(body))\\\" }) { success comment { id body createdAt user { id name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let commentCreate = data["commentCreate"] as? [String: Any],
              let success = commentCreate["success"] as? Bool,
              success,
              let comment = commentCreate["comment"] as? [String: Any] else { return nil }
        return parseComment(comment)
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
        let q = "{ issue(id: \\\"\(issueId)\\\") { id identifier title description url state { id name type } assignee { id name } project { id name } labels { nodes { name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let issue = data["issue"] as? [String: Any] else { return nil }
        return parseIssueDetail(issue)
    }

    func fetchIssues(teamId: String? = nil, projectId: String? = nil) async -> [LinearIssue] {
        guard let token = loadToken() else {
            DevLog.shared.error("Linear", "fetchIssues: no token")
            return []
        }
        var filterParts: [String] = []
        if let tid = teamId, !tid.isEmpty {
            filterParts.append("team: { id: { eq: \\\"\(tid)\\\" } }")
        }
        if let pid = projectId, !pid.isEmpty {
            filterParts.append("project: { id: { eq: \\\"\(pid)\\\" } }")
        }
        let filterArg = filterParts.isEmpty ? "(first: 50)" : "(filter: { \(filterParts.joined(separator: ", ")) }, first: 50)"
        let q = "{ issues\(filterArg) { nodes { id identifier title description url state { id name type } assignee { id name } project { id name } labels { nodes { name } } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else {
            DevLog.shared.error("Linear", "fetchIssues: query failed")
            return []
        }
        guard let data = json["data"] as? [String: Any],
              let issues = data["issues"] as? [String: Any],
              let nodes = issues["nodes"] as? [[String: Any]] else {
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                DevLog.shared.error("Linear", "fetchIssues errors: \(msg)")
            }
            return []
        }
        return nodes.compactMap { parseIssueDetail($0) }
    }

    func searchIssues(query searchText: String, teamId: String? = nil) async -> [LinearIssue] {
        guard let token = loadToken() else {
            DevLog.shared.error("Linear", "searchIssues: no token")
            return []
        }
        var filterArg = ""
        if let tid = teamId, !tid.isEmpty {
            filterArg = ", filter: { team: { id: { eq: \\\"\(tid)\\\" } } }"
        }
        let escaped = escapeGraphQL(searchText)
        let q = "{ issueSearch(query: \\\"\(escaped)\\\"\(filterArg), first: 30) { nodes { id identifier title description url state { id name type } assignee { id name } project { id name } labels { nodes { name } } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else {
            DevLog.shared.error("Linear", "searchIssues: query failed")
            return []
        }
        guard let data = json["data"] as? [String: Any] else {
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                DevLog.shared.error("Linear", "searchIssues errors: \(msg)")
            }
            return []
        }
        guard let issueSearch = data["issueSearch"] as? [String: Any],
              let nodes = issueSearch["nodes"] as? [[String: Any]] else {
            DevLog.shared.error("Linear", "searchIssues: unexpected response structure: \(data.keys)")
            return []
        }
        return nodes.compactMap { parseIssueDetail($0) }
    }

    // MARK: - Sync

    func syncTrackedIssues() async {
        guard let store else { return }
        guard !isSyncing else {
            DevLog.shared.info("LinearSync", "sync already running, skipped")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let reverseMapping = Dictionary(store.linearConfig.assigneeMapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let issues = store.trackedIssues
        for issue in issues {
            guard let linearId = issue.linearIssueId, !linearId.isEmpty else { continue }
            let displayKey = issue.linearKey ?? linearId
            guard let detail = await fetchIssueDetail(issueId: linearId) else {
                DevLog.shared.info("LinearSync", "\(displayKey) fetch failed, skipped")
                continue
            }

            // Status sync
            if let state = detail.state {
                let newStatus = mapLinearState(state.name)
                if let newStatus,
                   let current = store.trackedIssues.first(where: { $0.id == issue.id }),
                   newStatus != current.status {
                    let oldLabel = current.status.rawValue
                    let newLabel = newStatus.rawValue
                    let commentText = "[Linear] 状态变更: \(oldLabel) → \(newLabel)（\(state.name)）"
                    store.updateIssueStatusLocally(id: issue.id, status: newStatus)
                    if !issueHasComment(issueId: issue.id, text: commentText) {
                        store.addIssueComment(id: issue.id, text: commentText)
                    }
                    DevLog.shared.info("LinearSync", "\(displayKey): \(oldLabel) → \(newLabel)")
                }
            }

            // Title sync. Remote Linear wins when the linked issue title changed elsewhere.
            if let current = store.trackedIssues.first(where: { $0.id == issue.id }),
               detail.title != current.title {
                let oldTitle = current.title
                store.updateIssueTitleLocally(id: issue.id, title: detail.title)
                let commentText = "[Linear] 标题变更: \(oldTitle) → \(detail.title)"
                if !issueHasComment(issueId: issue.id, text: commentText) {
                    store.addIssueComment(id: issue.id, text: commentText)
                }
                DevLog.shared.info("LinearSync", "\(displayKey): title updated")
            }

            // Project sync. Only apply when the Linear project has an explicit local mapping.
            if let remoteProjectId = detail.project?.id,
               let localDepartment = store.linearConfig.projectMapping.first(where: { $0.value == remoteProjectId })?.key,
               let current = store.trackedIssues.first(where: { $0.id == issue.id }),
               current.department != localDepartment {
                let oldDepartment = current.department ?? "未设置"
                store.updateIssueDepartmentLocally(id: issue.id, department: localDepartment)
                let commentText = "[Linear] 项目变更: \(oldDepartment) → \(localDepartment)"
                if !issueHasComment(issueId: issue.id, text: commentText) {
                    store.addIssueComment(id: issue.id, text: commentText)
                }
                DevLog.shared.info("LinearSync", "\(displayKey): project → \(localDepartment)")
            }

            // Assignee sync
            let remoteAssignee = detail.assignee?.name
            if let current = store.trackedIssues.first(where: { $0.id == issue.id }),
               remoteAssignee != current.linearAssignee {
                let oldName = current.linearAssignee ?? "无"
                let newName = remoteAssignee ?? "无"
                let commentText = "[Linear] 负责人变更: \(oldName) → \(newName)"
                store.updateIssueLinearAssignee(id: issue.id, assignee: remoteAssignee)
                if !issueHasComment(issueId: issue.id, text: commentText) {
                    store.addIssueComment(id: issue.id, text: commentText)
                }
                DevLog.shared.info("LinearSync", "\(displayKey): assignee \(oldName) → \(newName)")

                if let remoteId = detail.assignee?.id,
                   let localName = reverseMapping[remoteId] {
                    if current.assignee != localName {
                        store.updateIssueAssigneeLocally(id: issue.id, assignee: localName)
                    }
                } else if let remoteAssignee, current.assignee != remoteAssignee {
                    store.updateIssueAssigneeLocally(id: issue.id, assignee: remoteAssignee)
                } else if remoteAssignee == nil, current.assignee != nil {
                    store.updateIssueAssigneeLocally(id: issue.id, assignee: nil)
                }
            }

            // Label → Type sync
            if !detail.labels.isEmpty,
               !store.linearConfig.labelMapping.isEmpty,
               let current = store.trackedIssues.first(where: { $0.id == issue.id }) {
                for label in detail.labels {
                    if let typeRaw = store.linearConfig.labelMapping[label],
                       let mappedType = IssueType(rawValue: typeRaw),
                       mappedType != current.type {
                        store.updateIssueType(id: issue.id, type: mappedType)
                        DevLog.shared.info("LinearSync", "\(displayKey): type → \(mappedType.rawValue) (label: \(label))")
                        break
                    }
                }
            }

            // Comment sync
            let remoteComments = await fetchIssueComments(issueId: linearId)
            let freshIssue = store.trackedIssues.first { $0.id == issue.id }
            var existingLinearIds = Set((freshIssue ?? issue).comments.compactMap { c -> String? in
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
                existingLinearIds.insert(linearCommentId)
                DevLog.shared.info("LinearSync", "\(displayKey): synced comment \(rc.id)")
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
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: str) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: str)
    }

    private func issueHasComment(issueId: UUID, text: String) -> Bool {
        store?.trackedIssues.first(where: { $0.id == issueId })?.comments.contains { $0.text == text } ?? false
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
        var project: LinearProject?
        if let projectObj = node["project"] as? [String: Any],
           let pid = projectObj["id"] as? String,
           let pname = projectObj["name"] as? String {
            project = LinearProject(id: pid, name: pname)
        }
        var labels: [String] = []
        if let labelsObj = node["labels"] as? [String: Any],
           let labelNodes = labelsObj["nodes"] as? [[String: Any]] {
            labels = labelNodes.compactMap { $0["name"] as? String }
        }
        return LinearIssue(id: id, identifier: identifier, title: title, description: description,
                           state: state, assignee: assignee, project: project, labels: labels, url: url)
    }
}
