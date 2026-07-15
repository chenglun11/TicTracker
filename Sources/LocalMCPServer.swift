import Foundation
import Network
import Observation

@MainActor
@Observable
final class LocalMCPServer {
    static let shared = LocalMCPServer()

    nonisolated static let enabledKey = "localMCPEnabled"
    nonisolated static let portKey = "localMCPPort"
    nonisolated static let readAccessKeyKey = "localMCPReadAccessKey"
    nonisolated static let writeAccessKeyKey = "localMCPWriteAccessKey"

    private let log = DevLog.shared
    private var listener: NWListener?
    private weak var store: DataStore?
    private(set) var statusText = "未运行"
    private(set) var statusDetail = ""
    private(set) var runningURL = ""

    private init() {}

    var isRunning: Bool {
        !runningURL.isEmpty
    }

    func setup(store: DataStore) {
        self.store = store
        restart()
    }

    func restart() {
        stop()
        guard let store else { return }
        let config = LocalMCPConfig.current()
        guard config.enabled else {
            statusText = "未启用"
            statusDetail = ""
            log.info("MCP", "本地 MCP 未启用")
            return
        }
        guard config.hasAnyKey else {
            statusText = "启动失败"
            statusDetail = "请至少配置一个只读或可写 AK"
            log.error("MCP", statusDetail)
            return
        }

        let parameters = NWParameters.tcp
        let port = NWEndpoint.Port(rawValue: config.port) ?? NWEndpoint.Port(rawValue: 8765)!
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        do {
            let listener = try NWListener(using: parameters)
            statusText = "启动中"
            statusDetail = "正在监听 127.0.0.1:\(config.port)"
            runningURL = ""
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state, port: config.port)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection: connection, store: store, config: config)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            statusText = "启动失败"
            statusDetail = error.localizedDescription
            runningURL = ""
            log.error("MCP", "本地 MCP 启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        runningURL = ""
        if statusText != "未启用" {
            statusText = "未运行"
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            runningURL = "http://127.0.0.1:\(port)/mcp"
            statusText = "运行中"
            statusDetail = runningURL
            log.info("MCP", "本地 MCP 已启动 \(runningURL)")
        case .failed(let error):
            listener?.cancel()
            listener = nil
            runningURL = ""
            statusText = "启动失败"
            statusDetail = error.localizedDescription
            log.error("MCP", "本地 MCP 启动失败: \(error.localizedDescription)")
        case .cancelled:
            listener = nil
            runningURL = ""
            if statusText != "未启用" {
                statusText = "未运行"
            }
        default:
            break
        }
    }

    private func handle(connection: NWConnection, store: DataStore, config: LocalMCPConfig) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let response = await self.processRequest(data: data ?? Data(), store: store, config: config)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func processRequest(data: Data, store: DataStore, config: LocalMCPConfig) async -> Data {
        guard let raw = String(data: data, encoding: .utf8) else {
            return httpJSON(status: 400, body: ["error": "invalid request encoding"])
        }
        let request = parseHTTPRequest(raw)
        guard request.method == "POST", request.path == "/mcp" || request.path == "/mcp/v1" else {
            return httpJSON(status: 404, body: ["error": "not found"])
        }
        guard let session = config.session(for: request.headers) else {
            return httpJSON(status: 401, body: ["error": "missing or invalid mcp access key"])
        }
        guard let bodyData = request.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) else {
            return httpJSON(status: 400, body: rpcError(id: nil, code: -32700, message: "parse error"))
        }
        if let batch = json as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for item in batch {
                if item["id"] == nil { continue }
                responses.append(await handleRPC(item, session: session, store: store))
            }
            if responses.isEmpty {
                return httpEmpty(status: 202)
            }
            return httpJSON(status: 200, body: responses)
        }
        guard let object = json as? [String: Any] else {
            return httpJSON(status: 400, body: rpcError(id: nil, code: -32600, message: "invalid request"))
        }
        if object["id"] == nil {
            _ = await handleRPC(object, session: session, store: store)
            return httpEmpty(status: 202)
        }
        return httpJSON(status: 200, body: await handleRPC(object, session: session, store: store))
    }

    private func handleRPC(_ request: [String: Any], session: LocalMCPSession, store: DataStore) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        let method = request["method"] as? String ?? ""
        switch method {
        case "initialize":
            return rpcResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": [
                    "name": "tictacker-local-mcp",
                    "title": "TicTracker Local",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ]
            ])
        case "ping", "notifications/initialized":
            return rpcResult(id: id, result: [:])
        case "tools/list":
            return rpcResult(id: id, result: ["tools": tools(writeEnabled: session.canWrite)])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return rpcError(id: id, code: -32602, message: "invalid tools/call params")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try await callTool(name: name, arguments: arguments, session: session, store: store)
                return rpcResult(id: id, result: result)
            } catch {
                return rpcError(id: id, code: -32000, message: error.localizedDescription)
            }
        default:
            return rpcError(id: id, code: -32601, message: "method not found")
        }
    }

    private func callTool(name: String, arguments: [String: Any], session: LocalMCPSession, store: DataStore) async throws -> [String: Any] {
        switch name {
        case "tictacker.get_status":
            return textResult(statusPayload(store: store))
        case "tictacker.list_issues":
            return textResult(["issues": issueListPayload(store: store, arguments: arguments)])
        case "tictacker.add_click":
            try requireWrite(session)
            return try textResult(addClick(store: store, arguments: arguments))
        case "tictacker.create_issue":
            try requireWrite(session)
            let issue = try createLocalIssue(store: store, arguments: arguments, source: .manual)
            return textResult(["success": true, "issue": issuePayload(issue)])
        case "tictacker.update_issue_status":
            try requireWrite(session)
            return try textResult(updateIssueStatus(store: store, arguments: arguments))
        case "tictacker.add_issue_comment":
            try requireWrite(session)
            return try textResult(addIssueComment(store: store, arguments: arguments))
        case "tictacker.create_linear_issue":
            try requireWrite(session)
            let value = try await createLinearIssue(store: store, arguments: arguments)
            return textResult(value)
        default:
            throw LocalMCPError.message("unknown tool \(name)")
        }
    }

    private func createLocalIssue(store: DataStore, arguments: [String: Any], source: IssueSource) throws -> TrackedIssue {
        let title = stringArg(arguments, "title")
        guard !title.isEmpty else { throw LocalMCPError.message("title is required") }
        let type = issueType(from: stringArg(arguments, "type"))
        var issue = TrackedIssue(title: title, type: type)
        issue.issueNumber = store.nextIssueNumber
        store.nextIssueNumber += 1
        issue.dateKey = store.todayKey
        issue.source = source
        issue.department = optionalStringArg(arguments, "department")
        issue.ticketURL = optionalStringArg(arguments, "ticketUrl")
        issue.assignee = optionalStringArg(arguments, "assignee")
        issue.reporterId = optionalStringArg(arguments, "reporterId") ?? store.currentMember?.id.uuidString
        issue.reporterName = optionalStringArg(arguments, "reporterName") ?? store.currentMemberName.nilIfEmpty
        if issue.reporterId != nil || issue.reporterName != nil {
            issue.reportedAt = Date()
        }
        issue.issueTags = DataStore.normalizedIssueTags(stringArrayArg(arguments, "issueTags"))
        store.trackedIssues.append(issue)
        store.logOperation(module: "问题", action: "MCP新增", detail: "#\(issue.issueNumber) [\(issue.type.rawValue)] \(issue.title)")
        return issue
    }

    private func createLinearIssue(store: DataStore, arguments: [String: Any]) async throws -> [String: Any] {
        guard store.linearConfig.enabled else {
            throw LocalMCPError.message("Linear is not enabled")
        }
        let title = stringArg(arguments, "title")
        guard !title.isEmpty else { throw LocalMCPError.message("title is required") }
        let teamId = firstNonEmpty(stringArg(arguments, "teamId"), store.linearConfig.teamId)
        guard !teamId.isEmpty else { throw LocalMCPError.message("teamId is required") }
        let projectId = firstNonEmpty(stringArg(arguments, "projectId"), store.linearConfig.projectId)
        let localAssignee = optionalStringArg(arguments, "assignee")
        let assigneeId = firstNonEmpty(
            stringArg(arguments, "assigneeId"),
            localAssignee.flatMap { store.linearConfig.assigneeMapping[$0] } ?? "",
            store.linearConfig.defaultAssigneeId
        )
        let labelIds = stringArrayArg(arguments, "labelIds")
        guard let remote = await LinearService.shared.createIssue(
            title: title,
            description: optionalStringArg(arguments, "description"),
            teamId: teamId,
            projectId: projectId.isEmpty ? nil : projectId,
            assigneeId: assigneeId.isEmpty ? nil : assigneeId,
            labelIds: labelIds.isEmpty ? nil : labelIds
        ) else {
            throw LocalMCPError.message("failed to create Linear issue")
        }

        var issue = try createLocalIssue(store: store, arguments: arguments, source: .linear)
        store.updateIssueLinearLink(id: issue.id, issueId: remote.id, key: remote.identifier, url: remote.url)
        if let project = remote.project {
            store.updateIssueLinearProject(id: issue.id, projectId: project.id, name: project.name)
        }
        let assigneeName = localAssignee ?? remote.assignee?.name
        store.updateIssueLinearAssignee(id: issue.id, assignee: assigneeName)
        if let refreshed = store.trackedIssues.first(where: { $0.id == issue.id }) {
            issue = refreshed
        }
        store.addIssueComment(id: issue.id, text: "[Linear] 已创建: \(remote.identifier)")
        return ["success": true, "linearIssue": linearIssuePayload(remote), "issue": issuePayload(issue)]
    }

    private func updateIssueStatus(store: DataStore, arguments: [String: Any]) throws -> [String: Any] {
        let idText = stringArg(arguments, "id")
        guard let id = UUID(uuidString: idText) else { throw LocalMCPError.message("invalid issue id") }
        guard let status = IssueStatus(rawValue: stringArg(arguments, "status")) ?? IssueStatus.fromCaseName(stringArg(arguments, "status")) else {
            throw LocalMCPError.message("invalid status")
        }
        guard store.trackedIssues.contains(where: { $0.id == id }) else {
            throw LocalMCPError.message("issue not found")
        }
        store.updateIssueStatus(id: id, status: status)
        return ["success": true]
    }

    private func addIssueComment(store: DataStore, arguments: [String: Any]) throws -> [String: Any] {
        let idText = stringArg(arguments, "id")
        guard let id = UUID(uuidString: idText) else { throw LocalMCPError.message("invalid issue id") }
        let text = stringArg(arguments, "text")
        guard !text.isEmpty else { throw LocalMCPError.message("text is required") }
        guard store.trackedIssues.contains(where: { $0.id == id }) else {
            throw LocalMCPError.message("issue not found")
        }
        store.addIssueComment(id: id, text: text, syncToLinear: boolArg(arguments, "syncToLinear"))
        return ["success": true]
    }

    private func addClick(store: DataStore, arguments: [String: Any]) throws -> [String: Any] {
        let department = stringArg(arguments, "department")
        guard !department.isEmpty else { throw LocalMCPError.message("department is required") }
        let dateKey = optionalStringArg(arguments, "dateKey") ?? store.todayKey
        let count = max(1, min(arguments["count"] as? Int ?? 1, 100))
        for _ in 0..<count {
            store.incrementForKey(dateKey, dept: department)
        }
        let dayRecords = store.recordsForKey(dateKey)
        return [
            "success": true,
            "dateKey": dateKey,
            "department": department,
            "added": count,
            "departmentTotal": dayRecords[department, default: 0],
            "dayTotal": store.totalForKey(dateKey)
        ]
    }

    private func statusPayload(store: DataStore) -> [String: Any] {
        let today = store.todayKey
        var newToday = 0
        var resolvedToday = 0
        var pending = 0
        var scheduled = 0
        var testing = 0
        var observing = 0
        for issue in store.trackedIssues {
            if issue.dateKey == today, !issue.isEffectivelyResolved {
                newToday += 1
            }
            if let resolvedAt = issue.resolvedAt, DataStore.dateKey(from: resolvedAt) == today {
                resolvedToday += 1
            }
            switch issue.effectiveStatus {
            case .scheduled:
                scheduled += 1
            case .testing:
                testing += 1
            case .observing:
                observing += 1
            case .inProgress:
                break
            default:
                if !issue.isEffectivelyResolved {
                    pending += 1
                }
            }
        }
        return [
            "statistics": [
                "newToday": newToday,
                "resolvedToday": resolvedToday,
                "pending": pending,
                "scheduled": scheduled,
                "testing": testing,
                "observing": observing
            ],
            "todayTotal": store.todayTotal,
            "departments": store.departments
        ]
    }

    private func issueListPayload(store: DataStore, arguments: [String: Any]) -> [[String: Any]] {
        let status = stringArg(arguments, "status")
        let limit = arguments["limit"] as? Int ?? 0
        var issues = store.trackedIssues.filter { issue in
            switch status {
            case "":
                return true
            case "new":
                return issue.dateKey == store.todayKey && !issue.isEffectivelyResolved
            case "pending":
                return !issue.isEffectivelyResolved && issue.effectiveStatus != .observing && issue.effectiveStatus != .scheduled && issue.effectiveStatus != .testing && issue.effectiveStatus != .inProgress
            case "scheduled":
                return issue.effectiveStatus == .scheduled
            case "testing":
                return issue.effectiveStatus == .testing
            case "observing":
                return issue.effectiveStatus == .observing
            case "resolved":
                return issue.isEffectivelyResolved
            default:
                return issue.effectiveStatus.rawValue == status || issue.effectiveStatus.caseName == status
            }
        }
        issues.sort { $0.issueNumber > $1.issueNumber }
        if limit > 0, issues.count > limit {
            issues = Array(issues.prefix(limit))
        }
        return issues.map(issuePayload)
    }

    private func issuePayload(_ issue: TrackedIssue) -> [String: Any] {
        var value: [String: Any] = [
            "id": issue.id.uuidString,
            "issueNumber": issue.issueNumber,
            "type": issue.type.rawValue,
            "title": issue.title,
            "dateKey": issue.dateKey,
            "createdAt": isoString(issue.createdAt),
            "status": issue.status.rawValue,
            "statusCase": issue.status.caseName,
            "effectiveStatus": issue.effectiveStatus.rawValue,
            "effectiveStatusCase": issue.effectiveStatus.caseName,
            "displayStatus": issue.displayStatusName,
            "source": issue.source.rawValue,
            "comments": issue.comments.map(commentPayload),
            "issueTags": issue.issueTags
        ]
        setOptional(&value, "updatedAt", issue.updatedAt.map(isoString))
        setOptional(&value, "assignee", issue.assignee)
        setOptional(&value, "ticketUrl", issue.ticketURL)
        setOptional(&value, "department", issue.department)
        setOptional(&value, "resolvedAt", issue.resolvedAt.map(isoString))
        setOptional(&value, "linearIssueId", issue.linearIssueId)
        setOptional(&value, "linearKey", issue.linearKey)
        setOptional(&value, "linearUrl", issue.linearUrl)
        setOptional(&value, "linearProjectId", issue.linearProjectId)
        setOptional(&value, "linearProjectName", issue.linearProjectName)
        setOptional(&value, "linearAssignee", issue.linearAssignee)
        setOptional(&value, "reporterId", issue.reporterId)
        setOptional(&value, "reporterName", issue.reporterName)
        setOptional(&value, "reportedAt", issue.reportedAt.map(isoString))
        return value
    }

    private func commentPayload(_ comment: IssueComment) -> [String: Any] {
        var value: [String: Any] = [
            "id": comment.id.uuidString,
            "text": comment.text,
            "createdAt": isoString(comment.createdAt)
        ]
        setOptional(&value, "jiraCommentId", comment.jiraCommentId)
        return value
    }

    private func linearIssuePayload(_ issue: LinearIssue) -> [String: Any] {
        var value: [String: Any] = [
            "id": issue.id,
            "identifier": issue.identifier,
            "title": issue.title,
            "url": issue.url
        ]
        if let project = issue.project {
            value["project"] = ["id": project.id, "name": project.name]
        }
        if let assignee = issue.assignee {
            value["assignee"] = ["id": assignee.id, "name": assignee.name]
        }
        return value
    }

    private func tools(writeEnabled: Bool) -> [[String: Any]] {
        var list: [[String: Any]] = [
            tool("tictacker.get_status", "读取今日计数、问题状态统计和部门列表。", properties: [:], required: []),
            tool("tictacker.list_issues", "读取问题追踪列表，支持 status 与 limit。", properties: [
                "status": ["type": "string"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200]
            ], required: [])
        ]
        if writeEnabled {
            list.append(tool("tictacker.add_click", "给指定部门新增点击计数。", properties: [
                "department": ["type": "string"],
                "dateKey": ["type": "string", "description": "可选，格式 yyyy-MM-dd；默认今天。"],
                "count": ["type": "integer", "minimum": 1, "maximum": 100]
            ], required: ["department"]))
            list.append(tool("tictacker.create_issue", "新增本地问题追踪记录。", properties: createIssueProperties(), required: ["title", "type"]))
            list.append(tool("tictacker.update_issue_status", "更新问题状态。", properties: [
                "id": ["type": "string"],
                "status": ["type": "string"]
            ], required: ["id", "status"]))
            list.append(tool("tictacker.add_issue_comment", "给问题追加备注。", properties: [
                "id": ["type": "string"],
                "text": ["type": "string"],
                "syncToLinear": ["type": "boolean"]
            ], required: ["id", "text"]))
            var linearProps = createIssueProperties()
            linearProps["description"] = ["type": "string"]
            linearProps["teamId"] = ["type": "string"]
            linearProps["projectId"] = ["type": "string"]
            linearProps["assigneeId"] = ["type": "string"]
            linearProps["labelIds"] = ["type": "array", "items": ["type": "string"]]
            list.append(tool("tictacker.create_linear_issue", "在 Linear 创建 issue，并同步生成本地问题追踪记录。", properties: linearProps, required: ["title"]))
        }
        return list
    }

    private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }

    private func createIssueProperties() -> [String: Any] {
        [
            "title": ["type": "string"],
            "type": ["type": "string"],
            "department": ["type": "string"],
            "ticketUrl": ["type": "string"],
            "reporterId": ["type": "string"],
            "reporterName": ["type": "string"],
            "assignee": ["type": "string"],
            "issueTags": ["type": "array", "items": ["type": "string"]]
        ]
    }

    private func textResult(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ["content": [["type": "text", "text": text]]]
    }

    private func requireWrite(_ session: LocalMCPSession) throws {
        guard session.canWrite else {
            throw LocalMCPError.message("write permission required")
        }
    }
}

private struct LocalMCPConfig {
    var enabled: Bool
    var port: UInt16
    var readKey: String
    var writeKey: String

    var hasAnyKey: Bool {
        !readKey.isEmpty || !writeKey.isEmpty
    }

    static func current() -> LocalMCPConfig {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        let envEnabled = env["TICTRACKER_MCP_ENABLED"].map { $0 == "1" || $0.lowercased() == "true" }
        let configuredEnabled = envEnabled ?? defaults.bool(forKey: LocalMCPServer.enabledKey)
        let portText = env["TICTRACKER_MCP_PORT"]
        let port = UInt16(portText ?? "") ?? UInt16(defaults.integer(forKey: LocalMCPServer.portKey)).nonZero ?? 8765
        return LocalMCPConfig(
            enabled: configuredEnabled,
            port: port,
            readKey: env["TICTRACKER_MCP_READ_AK"] ?? defaults.string(forKey: LocalMCPServer.readAccessKeyKey) ?? "",
            writeKey: env["TICTRACKER_MCP_WRITE_AK"] ?? defaults.string(forKey: LocalMCPServer.writeAccessKeyKey) ?? ""
        )
    }

    func session(for headers: [String: String]) -> LocalMCPSession? {
        let ak = headers["x-tictracker-ak"] ?? headers["x-api-key"] ?? bearerToken(headers["authorization"] ?? "")
        guard let ak, !ak.isEmpty else { return nil }
        if constantTimeEquals(ak, writeKey) {
            return LocalMCPSession(canWrite: true)
        }
        if constantTimeEquals(ak, readKey) {
            return LocalMCPSession(canWrite: false)
        }
        return nil
    }

    private func bearerToken(_ value: String) -> String? {
        guard value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        guard !rhs.isEmpty else { return false }
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var diff = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            diff |= Int(l ^ r)
        }
        return diff == 0
    }
}

private struct LocalMCPSession {
    var canWrite: Bool
}

private enum LocalMCPError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct HTTPRequestParts {
    var method: String
    var path: String
    var headers: [String: String]
    var body: String
}

private func parseHTTPRequest(_ raw: String) -> HTTPRequestParts {
    let sections = raw.components(separatedBy: "\r\n\r\n")
    let head = sections.first ?? ""
    let body = sections.dropFirst().joined(separator: "\r\n\r\n")
    let lines = head.components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ") ?? []
    let method = first.count > 0 ? String(first[0]) : ""
    let path = first.count > 1 ? String(first[1]).components(separatedBy: "?").first ?? "" : ""
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let separator = line.firstIndex(of: ":") else { continue }
        let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        headers[name] = value
    }
    return HTTPRequestParts(method: method, path: path, headers: headers, body: body)
}

private func httpJSON(status: Int, body: Any) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
    return httpResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
}

private func httpEmpty(status: Int) -> Data {
    httpResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data())
}

private func httpResponse(status: Int, contentType: String, body: Data) -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 202: reason = "Accepted"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 404: reason = "Not Found"
    default: reason = "OK"
    }
    var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    response.append(body)
    return response
}

private func rpcResult(id: Any, result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

private func rpcError(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

private func stringArg(_ arguments: [String: Any], _ key: String) -> String {
    (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func optionalStringArg(_ arguments: [String: Any], _ key: String) -> String? {
    stringArg(arguments, key).nilIfEmpty
}

private func stringArrayArg(_ arguments: [String: Any], _ key: String) -> [String] {
    (arguments[key] as? [String]) ?? []
}

private func boolArg(_ arguments: [String: Any], _ key: String) -> Bool {
    arguments[key] as? Bool ?? false
}

private func issueType(from raw: String) -> IssueType {
    IssueType(rawValue: raw) ?? (raw == "Support" ? .issue : .bug)
}

private func firstNonEmpty(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

private func setOptional(_ target: inout [String: Any], _ key: String, _ value: String?) {
    guard let value, !value.isEmpty else { return }
    target[key] = value
}

private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension UInt16 {
    var nonZero: UInt16? {
        self == 0 ? nil : self
    }
}
