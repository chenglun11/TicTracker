import Foundation

struct LinearCandidateFetchResult: Sendable {
    let issues: [LinearIssue]
    let notice: String?
    let isComplete: Bool
}

@MainActor
@Observable
final class LinearService {
    static let shared = LinearService()
    private var store: DataStore?
    private var pollingTask: Task<Void, Never>?
    private var isSyncing = false
    private var cachedToken: String?

    private init() {}

    func setup(store: DataStore) {
        self.store = store
    }

    func updateCachedToken(_ token: String?) {
        cachedToken = token
    }

    func invalidateCachedToken() {
        cachedToken = nil
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
        var result: [LinearProject] = []
        var cursor: String?
        var hasNextPage = true

        while hasNextPage {
            let afterArg = cursor.map { ", after: \\\"\(escapeGraphQL($0))\\\"" } ?? ""
            let q = "{ team(id: \\\"\(escapeGraphQL(teamId))\\\") { projects(first: 100\(afterArg)) { nodes { id name } pageInfo { hasNextPage endCursor } } } }"
            let query = #"{"query":""# + q + #""}"#
            guard let json = await executeQuery(query: query, token: token) else { break }
            guard let data = json["data"] as? [String: Any],
                  let team = data["team"] as? [String: Any],
                  let projects = team["projects"] as? [String: Any],
                  let nodes = projects["nodes"] as? [[String: Any]] else { break }
            result += nodes.compactMap { node in
                guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
                return LinearProject(id: id, name: name)
            }
            if let pageInfo = projects["pageInfo"] as? [String: Any] {
                hasNextPage = pageInfo["hasNextPage"] as? Bool ?? false
                cursor = pageInfo["endCursor"] as? String
            } else {
                hasNextPage = false
            }
            if cursor?.isEmpty == true {
                hasNextPage = false
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            DevLog.shared.error("Linear", "createIssue: title is empty")
            return nil
        }
        let normalizedTeamId = teamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTeamId.isEmpty else {
            DevLog.shared.error("Linear", "createIssue: teamId is empty")
            return nil
        }

        var input: [String: Any] = [
            "title": normalizedTitle,
            "teamId": normalizedTeamId
        ]
        if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            input["description"] = desc
        }
        if let pid = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty {
            input["projectId"] = pid
        }
        let effectiveAssigneeId = assigneeId ?? {
            let defaultId = store?.linearConfig.defaultAssigneeId ?? ""
            return defaultId.isEmpty ? nil : defaultId
        }()
        if let aid = effectiveAssigneeId?.trimmingCharacters(in: .whitespacesAndNewlines), !aid.isEmpty {
            input["assigneeId"] = aid
        }
        if let ids = labelIds?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }), !ids.isEmpty {
            input["labelIds"] = ids
        }

        let mutation = """
        mutation CreateIssue($input: IssueCreateInput!) {
          issueCreate(input: $input) {
            success
            issue {
              id
              identifier
              title
              url
              createdAt
              updatedAt
              project { id name }
            }
          }
        }
        """
        guard let json = await executeGraphQL(query: mutation, variables: ["input": input], token: token, operation: "createIssue") else { return nil }
        guard let data = json["data"] as? [String: Any],
              let issueCreate = data["issueCreate"] as? [String: Any],
              let success = issueCreate["success"] as? Bool, success,
              let issue = issueCreate["issue"] as? [String: Any] else {
            if graphQLErrorMessages(from: json).isEmpty {
                DevLog.shared.error("Linear", "createIssue: unexpected response \(json.keys.sorted())")
            }
            return nil
        }
        return parseIssueDetail(issue)
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
        let q = "{ issue(id: \\\"\(issueId)\\\") { id identifier title description url createdAt updatedAt state { id name type } assignee { id name } creator { id name } team { id name key } project { id name } labels { nodes { name } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else { return nil }
        guard let data = json["data"] as? [String: Any],
              let issue = data["issue"] as? [String: Any] else { return nil }
        return parseIssueDetail(issue)
    }

    func fetchIssueByIdentifier(_ identifier: String) async -> LinearIssue? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }

        // Linear's issue(id:) lookup expects the entity UUID. Passing a human-readable
        // identifier such as "ENG-123" produces an expected-but-noisy
        // "Entity not found: Issue" GraphQL error before the fallback succeeds.
        if UUID(uuidString: normalized) != nil {
            return await fetchIssueDetail(issueId: normalized)
        }
        if let exact = await fetchIssueByTeamKeyAndNumber(identifier: normalized) {
            return exact
        }
        let results = await searchIssues(query: normalized, teamId: nil)
        return results.first {
            $0.identifier.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private func fetchIssueByTeamKeyAndNumber(identifier: String) async -> LinearIssue? {
        guard let token = loadToken() else {
            DevLog.shared.error("Linear", "fetchIssueByIdentifier: no token")
            return nil
        }
        let parts = identifier.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let number = Int(parts[1]) else { return nil }
        let teamKey = escapeGraphQL(parts[0])
        let q = "{ issues(first: 1, filter: { team: { key: { eq: \\\"\(teamKey)\\\" } }, number: { eq: \(number) } }) { nodes { id identifier title description url createdAt updatedAt state { id name type } assignee { id name } creator { id name } team { id name key } project { id name } labels { nodes { name } } } } }"
        let query = #"{"query":""# + q + #""}"#
        guard let json = await executeQuery(query: query, token: token) else {
            DevLog.shared.error("Linear", "fetchIssueByIdentifier: exact query failed")
            return nil
        }
        guard let data = json["data"] as? [String: Any],
              let issues = data["issues"] as? [String: Any],
              let nodes = issues["nodes"] as? [[String: Any]] else {
            if let errors = json["errors"] as? [[String: Any]] {
                let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                DevLog.shared.error("Linear", "fetchIssueByIdentifier errors: \(msg)")
            }
            return nil
        }
        return nodes.compactMap { parseIssueDetail($0) }.first {
            $0.identifier.localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    func fetchIssues(teamId: String? = nil, projectId: String? = nil) async -> [LinearIssue] {
        await fetchIssuesResult(teamId: teamId, projectId: projectId).issues
    }

    private struct LinearIssueFetchResult: Sendable {
        let issues: [LinearIssue]
        let notices: [String]
        let isComplete: Bool
    }

    private func fetchIssuesResult(
        teamId: String? = nil,
        projectId: String? = nil,
        pageSize: Int = 100,
        maximumIssues: Int? = nil,
        orderByCreatedAt: Bool = false
    ) async -> LinearIssueFetchResult {
        guard let token = loadToken() else {
            DevLog.shared.error("Linear", "fetchIssues: no token")
            return LinearIssueFetchResult(
                issues: [],
                notices: ["未找到 Linear API Token，请先在设置中完成连接"],
                isComplete: false
            )
        }
        var filterParts: [String] = []
        if let tid = teamId, !tid.isEmpty {
            filterParts.append("team: { id: { eq: \\\"\(tid)\\\" } }")
        }
        if let pid = projectId, !pid.isEmpty {
            filterParts.append("project: { id: { eq: \\\"\(pid)\\\" } }")
        }
        var cursor: String?
        var result: [LinearIssue] = []
        var notices: [String] = []
        var isComplete = true
        let maximumPages = 50
        for page in 0..<maximumPages {
            guard !Task.isCancelled else {
                isComplete = false
                break
            }
            var args = ["first: \(max(pageSize, 1))"]
            if orderByCreatedAt {
                args.append("orderBy: createdAt")
            }
            if !filterParts.isEmpty {
                args.insert("filter: { \(filterParts.joined(separator: ", ")) }", at: 0)
            }
            if let cursor, !cursor.isEmpty {
                args.append("after: \\\"\(escapeGraphQL(cursor))\\\"")
            }
            let q = "{ issues(\(args.joined(separator: ", "))) { nodes { id identifier title description url createdAt updatedAt state { id name type } assignee { id name } creator { id name } team { id name key } project { id name } labels { nodes { name } } } pageInfo { hasNextPage endCursor } } }"
            let query = #"{"query":""# + q + #""}"#
            guard let json = await executeQuery(query: query, token: token, retryTransientReadFailures: true) else {
                guard !Task.isCancelled else {
                    isComplete = false
                    break
                }
                DevLog.shared.error("Linear", "fetchIssues: query failed")
                notices.append("Linear 请求失败，候选结果可能不完整，请检查 Token 或网络后重试")
                isComplete = false
                break
            }
            guard let data = json["data"] as? [String: Any],
                  let issues = data["issues"] as? [String: Any],
                  let nodes = issues["nodes"] as? [[String: Any]] else {
                if let errors = json["errors"] as? [[String: Any]] {
                    let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
                    DevLog.shared.error("Linear", "fetchIssues errors: \(msg)")
                    notices.append(msg.isEmpty ? "Linear 返回异常，候选结果可能不完整" : "Linear：\(msg)")
                } else {
                    notices.append("Linear 返回异常，候选结果可能不完整")
                }
                isComplete = false
                break
            }
            result += nodes.compactMap { parseIssueDetail($0) }
            if maximumIssues != nil { break }
            guard let pageInfo = issues["pageInfo"] as? [String: Any],
                  pageInfo["hasNextPage"] as? Bool == true,
                  let nextCursor = pageInfo["endCursor"] as? String,
                  !nextCursor.isEmpty else {
                break
            }
            cursor = nextCursor
            if page == maximumPages - 1 {
                notices.append("Linear Issue 超过 5000 条，本次仅显示前 5000 条")
                isComplete = false
            }
        }
        return LinearIssueFetchResult(issues: result, notices: notices, isComplete: isComplete)
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
        let q = "{ issueSearch(query: \\\"\(escaped)\\\"\(filterArg), first: 30) { nodes { id identifier title description url createdAt updatedAt state { id name type } assignee { id name } creator { id name } team { id name key } project { id name } labels { nodes { name } } } } }"
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

        let candidateResult = await fetchImportCandidatesFromConfiguredScope(includeAllTeamIssues: false)
        let importCandidates = candidateResult.issues
        let importCandidateCount = importCandidates.count
        var autoImportedCount = 0
        if !candidateResult.isComplete {
            DevLog.shared.error("LinearSync", "candidate fetch incomplete; automatic import skipped until a complete retry succeeds")
        } else if store.linearConfig.autoImportCandidates {
            for candidate in importCandidates {
                if store.addIssueFromLinear(candidate) {
                    autoImportedCount += 1
                }
            }
            if autoImportedCount > 0 {
                DevLog.shared.info("LinearSync", "auto imported \(autoImportedCount) Linear candidate(s)")
            }
        }
        let reverseMapping = Dictionary(store.linearConfig.assigneeMapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let issues = store.trackedIssues
        var syncedCount = 0
        for issue in issues {
            var linearId = issue.linearIssueId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var detail: LinearIssue?
            if linearId.isEmpty,
               issue.source == .linear,
               let linearKey = issue.linearKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !linearKey.isEmpty {
                if let hydrated = await fetchIssueByIdentifier(linearKey) {
                    store.applyLinearIssueRemote(hydrated, to: issue.id, syncStatus: false)
                    detail = hydrated
                    linearId = hydrated.id
                    DevLog.shared.info("LinearSync", "\(linearKey): hydrated linked issue id=\(hydrated.id)")
                } else {
                    DevLog.shared.info("LinearSync", "\(linearKey): hydrate failed, skipped")
                    continue
                }
            }
            guard !linearId.isEmpty else { continue }
            syncedCount += 1
            let displayKey = issue.linearKey ?? linearId
            if detail == nil {
                detail = await fetchIssueDetail(issueId: linearId)
            }
            guard let detail else {
                DevLog.shared.info("LinearSync", "\(displayKey): fetch failed, skipped")
                continue
            }

            // Status sync
            if let state = detail.state {
                let newStatus = mapLinearState(state)
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

            // Project sync. Keep Linear metadata and the local project field aligned.
            if let remoteProject = detail.project {
                if let current = store.trackedIssues.first(where: { $0.id == issue.id }),
                   current.linearProjectId != remoteProject.id || current.linearProjectName != remoteProject.name || current.department != remoteProject.name {
                    store.updateIssueLinearProject(id: issue.id, projectId: remoteProject.id, name: remoteProject.name)
                    store.updateIssueDepartment(id: issue.id, department: remoteProject.name)
                }
            } else if let current = store.trackedIssues.first(where: { $0.id == issue.id }),
                      current.linearProjectId != nil || current.linearProjectName != nil {
                store.updateIssueLinearProject(id: issue.id, projectId: nil, name: nil)
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

            let remoteCreator = detail.creator?.name
            let remoteStateName = detail.state?.name
            let remoteStateType = detail.state?.type
            if let current = store.trackedIssues.first(where: { $0.id == issue.id }),
               remoteCreator != current.linearCreator ||
               remoteStateName != current.linearStateName ||
               remoteStateType != current.linearStateType ||
               detail.createdAt != current.linearCreatedAt ||
               detail.updatedAt != current.linearUpdatedAt {
                store.updateIssueLinearMetadata(
                    id: issue.id,
                    creator: remoteCreator,
                    stateName: remoteStateName,
                    stateType: remoteStateType,
                    createdAt: detail.createdAt,
                    updatedAt: detail.updatedAt
                )
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
        DevLog.shared.info("LinearSync", "sync completed: import_candidates=\(importCandidateCount), auto_imported=\(autoImportedCount), linked_checked=\(syncedCount)")
    }

    // MARK: - Private Helpers

    func fetchImportCandidatesFromConfiguredScope(includeAllTeamIssues: Bool = false, limit: Int? = 20) async -> LinearCandidateFetchResult {
        guard let store else {
            return LinearCandidateFetchResult(issues: [], notice: nil, isComplete: false)
        }
        let defaultTeamId = store.linearConfig.teamId.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredTeams = store.linearConfig.configuredTeams
        let importProjects = store.linearConfig.configuredImportProjects
        guard !configuredTeams.isEmpty || importProjects.contains(where: { $0.teamId?.isEmpty == false }) else {
            DevLog.shared.info("LinearSync", "candidate fetch skipped: teamId is empty")
            return LinearCandidateFetchResult(issues: [], notice: "尚未选择 Linear Team", isComplete: false)
        }
        let fetchResult: LinearIssueFetchResult
        if includeAllTeamIssues || importProjects.isEmpty {
            let scopes = configuredTeams.map { LinearIssueFetchScope(teamId: $0.id, projectId: nil) }
            fetchResult = await fetchIssuesConcurrently(scopes: scopes, limit: limit)
        } else {
            var scopes: [LinearIssueFetchScope] = []
            for project in importProjects {
                let projectTeamId = project.teamId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveTeamId: String
                if let projectTeamId, !projectTeamId.isEmpty {
                    effectiveTeamId = projectTeamId
                } else {
                    effectiveTeamId = defaultTeamId
                }
                guard !effectiveTeamId.isEmpty else { continue }
                scopes.append(LinearIssueFetchScope(teamId: effectiveTeamId, projectId: project.id))
            }
            fetchResult = await fetchIssuesConcurrently(scopes: scopes, limit: limit)
        }
        var candidates = fetchResult.issues.filter { remote in
            (includeAllTeamIssues || !importProjects.isEmpty || shouldAutoImportLinearIssue(remote)) && !store.hasIssueFromLinear(remote)
        }
        candidates = sortedLinearImportCandidates(candidates)
        if let limit {
            candidates = Array(candidates.prefix(limit))
        }
        let scopeText = includeAllTeamIssues || importProjects.isEmpty ? "team" : "\(importProjects.count) project(s)"
        let modeText = includeAllTeamIssues ? "manual" : "automatic"
        DevLog.shared.info("LinearSync", "found \(candidates.count) Linear import candidates [scope=\(scopeText), mode=\(modeText)]")
        let notices = Array(Set(fetchResult.notices)).sorted()
        return LinearCandidateFetchResult(
            issues: candidates,
            notice: notices.isEmpty ? nil : notices.joined(separator: "\n"),
            isComplete: fetchResult.isComplete
        )
    }

    private struct LinearIssueFetchScope: Sendable {
        let teamId: String
        let projectId: String?
    }

    private func fetchIssuesConcurrently(scopes: [LinearIssueFetchScope], limit: Int? = nil) async -> LinearIssueFetchResult {
        guard !scopes.isEmpty else {
            return LinearIssueFetchResult(issues: [], notices: [], isComplete: true)
        }
        let maximumConcurrentRequests = 4
        return await withTaskGroup(of: LinearIssueFetchResult.self, returning: LinearIssueFetchResult.self) { group in
            var nextScopeIndex = 0
            var result: [LinearIssue] = []
            var seen = Set<String>()
            var notices: [String] = []
            var isComplete = true

            for _ in 0..<min(maximumConcurrentRequests, scopes.count) {
                let scope = scopes[nextScopeIndex]
                nextScopeIndex += 1
                group.addTask { [self] in
                    await fetchIssuesResult(
                        teamId: scope.teamId,
                        projectId: scope.projectId,
                        pageSize: limit == nil ? 100 : max(limit ?? 100, 100),
                        maximumIssues: limit,
                        orderByCreatedAt: limit != nil
                    )
                }
            }

            while let fetchResult = await group.next() {
                for issue in fetchResult.issues where seen.insert(issue.id).inserted {
                    result.append(issue)
                }
                notices.append(contentsOf: fetchResult.notices)
                isComplete = isComplete && fetchResult.isComplete
                guard !Task.isCancelled else {
                    group.cancelAll()
                    isComplete = false
                    break
                }
                if nextScopeIndex < scopes.count {
                    let scope = scopes[nextScopeIndex]
                    nextScopeIndex += 1
                    group.addTask { [self] in
                        await fetchIssuesResult(
                            teamId: scope.teamId,
                            projectId: scope.projectId,
                            pageSize: limit == nil ? 100 : max(limit ?? 100, 100),
                            maximumIssues: limit,
                            orderByCreatedAt: limit != nil
                        )
                    }
                }
            }
            let issues = limit.map { Array(sortedLinearImportCandidates(result).prefix($0)) } ?? result
            return LinearIssueFetchResult(issues: issues, notices: notices, isComplete: isComplete)
        }
    }

    private func sortedLinearImportCandidates(_ issues: [LinearIssue]) -> [LinearIssue] {
        issues.sorted { lhs, rhs in
            let lhsDone = isDoneLinearState(lhs.state)
            let rhsDone = isDoneLinearState(rhs.state)
            if lhsDone != rhsDone { return !lhsDone }
            let lhsDate = parseISO8601(lhs.createdAt) ?? .distantPast
            let rhsDate = parseISO8601(rhs.createdAt) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedDescending
        }
    }

    private func isDoneLinearState(_ state: LinearState?) -> Bool {
        guard let state else { return false }
        let name = LinearConfig.normalizedStatusName(state.name)
        let type = state.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return type == "completed" || name == "done"
    }

    private func shouldAutoImportLinearIssue(_ issue: LinearIssue) -> Bool {
        let labels = Set(issue.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if labels.contains("feedback") && labels.contains("feishu") {
            return true
        }
        let description = issue.description ?? ""
        return description.contains("来源：飞书多维表反馈工单") ||
            (description.contains("Record ID：") && description.contains("Event ID："))
    }

    private func loadToken() -> String? {
        if let cachedToken {
            return cachedToken
        }
        guard let data = KeychainHelper.load(
            service: KeychainHelper.service,
            account: LinearConfig.keychainTokenKey
        ) else {
            return nil
        }
        let token = String(data: data, encoding: .utf8)
        cachedToken = token
        return token
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

    private func performGraphQLRequest(query: String, variables: [String: Any]? = nil, token: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: "https://api.linear.app/graphql") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["query": query]
        if let variables {
            payload["variables"] = variables
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await URLSession.shared.data(for: request)
    }

    private func executeGraphQL(query: String, variables: [String: Any]? = nil, token: String, operation: String) async -> [String: Any]? {
        do {
            let (data, response) = try await performGraphQLRequest(query: query, variables: variables, token: token)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = response as? HTTPURLResponse {
                    DevLog.shared.error("Linear", "\(operation) HTTP \(http.statusCode): \(responsePreview(data))")
                }
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DevLog.shared.error("Linear", "\(operation): invalid JSON response \(responsePreview(data))")
                return nil
            }
            let messages = graphQLErrorMessages(from: json)
            if !messages.isEmpty {
                DevLog.shared.error("Linear", "\(operation) GraphQL errors: \(messages.joined(separator: "; "))")
            }
            return json
        } catch {
            DevLog.shared.error("Linear", "\(operation) request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func executeQuery(
        query: String,
        token: String,
        retryTransientReadFailures: Bool = false
    ) async -> [String: Any]? {
        let maximumAttempts = retryTransientReadFailures ? 4 : 1
        for attempt in 0..<maximumAttempts {
            do {
                let (data, response) = try await performRequest(query: query, token: token)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    guard let http = response as? HTTPURLResponse else { return nil }
                    DevLog.shared.error("Linear", "HTTP \(http.statusCode): \(responsePreview(data))")
                    let isTransient = http.statusCode == 429 || (500...599).contains(http.statusCode)
                    if retryTransientReadFailures, isTransient, attempt + 1 < maximumAttempts {
                        guard await waitBeforeLinearRetry(response: http, attempt: attempt) else { return nil }
                        continue
                    }
                    return nil
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DevLog.shared.error("Linear", "invalid JSON response \(responsePreview(data))")
                    return nil
                }
                let messages = graphQLErrorMessages(from: json)
                if !messages.isEmpty {
                    DevLog.shared.error("Linear", "GraphQL errors: \(messages.joined(separator: "; "))")
                }
                return json
            } catch {
                if Task.isCancelled || isCancellationError(error) {
                    return nil
                }
                DevLog.shared.error("Linear", "request failed: \(error.localizedDescription)")
                if retryTransientReadFailures, attempt + 1 < maximumAttempts {
                    guard await waitBeforeLinearRetry(response: nil, attempt: attempt) else { return nil }
                    continue
                }
                return nil
            }
        }
        return nil
    }

    private nonisolated func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cancelled
    }

    private func waitBeforeLinearRetry(response: HTTPURLResponse?, attempt: Int) async -> Bool {
        let retryAfter = response?
            .value(forHTTPHeaderField: "Retry-After")
            .flatMap(Double.init)
        let fallback = min(0.5 * pow(2, Double(attempt)), 8)
        let delay = max(retryAfter ?? fallback, 0)
        do {
            try await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private nonisolated func graphQLErrorMessages(from json: [String: Any]) -> [String] {
        guard let errors = json["errors"] as? [[String: Any]] else { return [] }
        return errors.compactMap { error in
            if let message = error["message"] as? String {
                return message
            }
            return String(describing: error)
        }
    }

    private nonisolated func responsePreview(_ data: Data, maxLength: Int = 500) -> String {
        let body = String(data: data, encoding: .utf8) ?? "(non-utf8 body, \(data.count) bytes)"
        guard body.count > maxLength else { return body }
        return "\(body.prefix(maxLength))…"
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

    private func mapLinearState(_ state: LinearState) -> IssueStatus? {
        guard let store else { return nil }
        if let localCase = store.linearConfig.mappedStatusCase(for: state.name),
           let matched = IssueStatus.fromCaseName(localCase) {
            return matched
        }
        switch state.type.lowercased() {
        case "completed": return .fixed
        case "canceled": return .ignored
        case "started": return .inProgress
        case "triage", "backlog", "unstarted": return .pending
        default: return nil
        }
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
        let createdAt = node["createdAt"] as? String
        let updatedAt = node["updatedAt"] as? String
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
        var creator: LinearUser?
        if let creatorObj = node["creator"] as? [String: Any],
           let creatorID = creatorObj["id"] as? String,
           let creatorName = creatorObj["name"] as? String {
            creator = LinearUser(id: creatorID, name: creatorName)
        }
        var team: LinearTeam?
        if let teamObj = node["team"] as? [String: Any],
           let teamID = teamObj["id"] as? String,
           let teamName = teamObj["name"] as? String,
           let teamKey = teamObj["key"] as? String {
            team = LinearTeam(id: teamID, name: teamName, key: teamKey)
        }
        var project: LinearProject?
        if let projectObj = node["project"] as? [String: Any],
           let pid = projectObj["id"] as? String,
           let pname = projectObj["name"] as? String {
            project = LinearProject(id: pid, name: pname, teamId: team?.id, teamName: team?.name)
        }
        var labels: [String] = []
        if let labelsObj = node["labels"] as? [String: Any],
           let labelNodes = labelsObj["nodes"] as? [[String: Any]] {
            labels = labelNodes.compactMap { $0["name"] as? String }
        }
        return LinearIssue(id: id, identifier: identifier, title: title, description: description,
                           state: state, assignee: assignee, creator: creator, team: team, project: project, labels: labels, url: url,
                           createdAt: createdAt, updatedAt: updatedAt)
    }
}
