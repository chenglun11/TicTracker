import Foundation

struct FeishuTaskCandidate: Identifiable, Codable, Sendable {
    var id: String { guid }
    var guid: String
    var summary: String
    var completedAt: String?
    var tasklistGUIDs: Set<String> = []
    var assigneeIDs: [String] = []
    var assigneeNameByID: [String: String] = [:]

    init(
        guid: String,
        summary: String,
        completedAt: String?,
        tasklistGUIDs: Set<String> = [],
        assigneeIDs: [String] = [],
        assigneeNameByID: [String: String] = [:]
    ) {
        self.guid = guid
        self.summary = summary
        self.completedAt = completedAt
        self.tasklistGUIDs = tasklistGUIDs
        self.assigneeIDs = assigneeIDs
        self.assigneeNameByID = assigneeNameByID
    }

    private enum CodingKeys: String, CodingKey {
        case guid, summary, completedAt, tasklistGUIDs, assigneeIDs, assigneeNameByID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decode(String.self, forKey: .guid)
        summary = try container.decode(String.self, forKey: .summary)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        tasklistGUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .tasklistGUIDs) ?? []
        assigneeIDs = try container.decodeIfPresent([String].self, forKey: .assigneeIDs) ?? []
        assigneeNameByID = try container.decodeIfPresent([String: String].self, forKey: .assigneeNameByID) ?? [:]
    }
}

struct FeishuTaskListResult: Codable, Sendable {
    var tasklists: [String]
    var selected: String
    var tasks: [FeishuTaskCandidate]
}

struct FeishuTaskTestResult: Codable, Sendable {
    var success: Bool
    var selectedTasklist: String
    var count: Int
    var preview: [String]
}

enum FeishuTaskServiceError: LocalizedError {
    case notConfigured
    case missingUserToken
    case invalidResponse
    case unauthorized
    case notFound
    case permissionDenied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先配置飞书任务清单 GUID"
        case .missingUserToken:
            return "请先在设置页粘贴 User Access Token (u-...)"
        case .invalidResponse:
            return "飞书响应无效"
        case .unauthorized:
            return "飞书授权已失效，请重新授权"
        case .notFound:
            return "飞书任务不存在或已删除"
        case .permissionDenied(let message):
            return message
        case .server(let message):
            return message
        }
    }
}

struct FeishuVisibleTasklist: Sendable {
    var guid: String
    var name: String
}

@MainActor
final class FeishuTaskService {
    static let shared = FeishuTaskService()

    struct BoundTaskSyncResult: Sendable {
        var tasks: [String: FeishuTaskCandidate]
        var deletedGUIDs: Set<String>
    }

    private struct TenantTokenBundle {
        var token: String
        var expireAt: Date
    }

    private var cachedTenantToken: TenantTokenBundle?

    func syncBoundTasks(store: DataStore, boundGUIDs: [String]) async throws -> BoundTaskSyncResult {
        guard !boundGUIDs.isEmpty else { return BoundTaskSyncResult(tasks: [:], deletedGUIDs: []) }
        var result: [String: FeishuTaskCandidate] = [:]
        var deletedGUIDs = Set<String>()
        var failedCount = 0
        for guid in boundGUIDs {
            do {
                let token = try await accessToken(for: store)
                let detail = try await self.getTaskDetail(guid: guid, token: token)
                let task = await self.enrichAssigneeNames(in: detail, store: store, token: token)
                result[guid] = task
            } catch FeishuTaskServiceError.notFound {
                deletedGUIDs.insert(guid)
                DevLog.shared.info("FeishuTask", "任务不存在或已删除，将解绑本地关联 [guid=\(guid)]")
            } catch {
                failedCount += 1
                DevLog.shared.error("FeishuTask", "拉取已绑定任务失败 [guid=\(guid), error=\(error.localizedDescription)]")
            }
        }
        DevLog.shared.info("FeishuTask", "单向同步完成：检查 \(boundGUIDs.count) 个绑定，成功 \(result.count)，解绑 \(deletedGUIDs.count)，失败 \(failedCount)")
        return BoundTaskSyncResult(tasks: result, deletedGUIDs: deletedGUIDs)
    }

    func taskDetail(store: DataStore, guid: String) async throws -> FeishuTaskCandidate {
        let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeishuTaskServiceError.invalidResponse }
        let token = try await accessToken(for: store)
        let task = try await getTaskDetail(guid: trimmed, token: token)
        return await enrichAssigneeNames(in: task, store: store, token: token)
    }

    private func getTaskDetail(guid: String, token: String) async throws -> FeishuTaskCandidate {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/task/v2/tasks/\(guid)") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            DevLog.shared.error("FeishuTask", "读取任务详情失败 [guid=\(guid), http=\(status), body=\(body.prefix(300))]")
            if status == 401 { throw FeishuTaskServiceError.unauthorized }
            if status == 404 { throw FeishuTaskServiceError.notFound }
            throw FeishuTaskServiceError.invalidResponse
        }
        let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = payload["code"] as? Int, code != 0 {
            let msg = payload["msg"] as? String ?? "读取任务详情失败"
            DevLog.shared.error("FeishuTask", "任务详情接口返回错误 [guid=\(guid), code=\(code), msg=\(msg)]")
            if code == 99991663 || code == 99991664 { throw FeishuTaskServiceError.unauthorized }
            if isNotFoundMessage(msg) { throw FeishuTaskServiceError.notFound }
            throw FeishuTaskServiceError.server(msg)
        }
        guard let dataObj = payload["data"] as? [String: Any],
              let task = dataObj["task"] as? [String: Any] else {
            throw FeishuTaskServiceError.invalidResponse
        }
        return makeTaskCandidate(from: task, fallbackGUID: guid)
    }

    func listTasks(store: DataStore, tasklistGUID: String? = nil) async throws -> FeishuTaskListResult {
        let tasklists = configuredTasklists(from: store)
        let selected = normalizedTasklist(tasklistGUID, fallback: tasklists.first) ?? ""
        guard !selected.isEmpty else {
            DevLog.shared.error("FeishuTask", "未配置任务清单 GUID")
            throw FeishuTaskServiceError.notConfigured
        }
        let token = try await accessToken(for: store)
        let rawTasks = try await self.listTasklistTasks(tasklistGUID: selected, token: token)
        let tasks = await self.enrichAssigneeNames(in: rawTasks, store: store, token: token)
        DevLog.shared.info("FeishuTask", "拉取任务清单成功 [mode=\(store.feishuBotConfig.taskAuthMode.rawValue), tasklist=\(selected), count=\(tasks.count)]")
        return FeishuTaskListResult(tasklists: tasklists, selected: selected, tasks: tasks)
    }

    func testTasks(store: DataStore) async throws -> FeishuTaskTestResult {
        let configuredGUIDs = configuredTasklists(from: store)
        guard let selected = configuredGUIDs.first, !selected.isEmpty else {
            DevLog.shared.error("FeishuTask", "未配置任务清单 GUID")
            throw FeishuTaskServiceError.notConfigured
        }

        let token = try await accessToken(for: store)
        let rawTasks = try await self.listTasklistTasks(tasklistGUID: selected, token: token)
        let tasks = await self.enrichAssigneeNames(in: rawTasks, store: store, token: token)
        DevLog.shared.info("FeishuTask", "\(store.feishuBotConfig.taskAuthMode.rawValue) 拉到 \(tasks.count) 条任务 [tasklist=\(selected)]")
        for task in tasks.prefix(10) {
            DevLog.shared.info("FeishuTask", "  任务: \(task.summary) [guid=\(task.guid)]")
        }

        let preview = Array(tasks.prefix(5).map { $0.summary.isEmpty ? $0.guid : $0.summary })
        return FeishuTaskTestResult(
            success: true,
            selectedTasklist: selected,
            count: tasks.count,
            preview: preview
        )
    }

    private func accessToken(for store: DataStore) async throws -> String {
        switch store.feishuBotConfig.taskAuthMode {
        case .userOAuth:
            return try await userAccessToken(store: store)
        case .botTenant:
            return try await tenantAccessToken(store: store)
        }
    }

    private func userAccessToken(store: DataStore) async throws -> String {
        try await userAccessToken(store: store, forceRefresh: false)
    }

    private func userAccessToken(store: DataStore, forceRefresh: Bool) async throws -> String {
        let appID = store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = FeishuBotService.loadAppSecret()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appID.isEmpty, !appSecret.isEmpty else {
            DevLog.shared.error("FeishuTask", "App ID 或 App Secret 缺失")
            throw FeishuTaskServiceError.notConfigured
        }
        do {
            if forceRefresh {
                return try await FeishuOAuthService.shared.forceRefreshAccessToken(appID: appID, appSecret: appSecret)
            }
            return try await FeishuOAuthService.shared.validAccessToken(appID: appID, appSecret: appSecret)
        } catch {
            DevLog.shared.error("FeishuTask", "获取 user_access_token 失败：\(error.localizedDescription)")
            throw error
        }
    }

    private func performWithFreshUserToken<T>(store: DataStore, operation: (String) async throws -> T) async throws -> T {
        let token = try await userAccessToken(store: store)
        do {
            return try await operation(token)
        } catch FeishuTaskServiceError.unauthorized {
            let refreshed = try await userAccessToken(store: store, forceRefresh: true)
            return try await operation(refreshed)
        }
    }

    private func tenantAccessToken(store: DataStore) async throws -> String {
        let now = Date()
        if let cachedTenantToken, cachedTenantToken.expireAt.timeIntervalSince(now) > 300 {
            return cachedTenantToken.token
        }

        let appID = store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = FeishuBotService.loadAppSecret()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appID.isEmpty, !appSecret.isEmpty else {
            DevLog.shared.error("FeishuTask", "App ID 或 App Secret 缺失")
            throw FeishuTaskServiceError.notConfigured
        }
        guard let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_id": appID,
            "app_secret": appSecret
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard status == 200 else {
            DevLog.shared.error("FeishuTask", "获取 tenant_access_token 失败 [status=\(status), body=\(body.prefix(300))]")
            throw FeishuTaskServiceError.invalidResponse
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeishuTaskServiceError.invalidResponse
        }
        if let code = payload["code"] as? Int, code != 0 {
            let msg = payload["msg"] as? String ?? body
            DevLog.shared.error("FeishuTask", "tenant_access_token 返回错误 [code=\(code), msg=\(msg)]")
            throw FeishuTaskServiceError.server(msg)
        }
        guard let token = payload["tenant_access_token"] as? String, !token.isEmpty else {
            throw FeishuTaskServiceError.invalidResponse
        }
        let expire = (payload["expire"] as? NSNumber)?.doubleValue ?? 7200
        cachedTenantToken = TenantTokenBundle(token: token, expireAt: now.addingTimeInterval(expire))
        DevLog.shared.info("FeishuTask", "tenant_access_token 已刷新，有效约 \(Int(expire)) 秒")
        return token
    }

    private func configuredTasklists(from store: DataStore) -> [String] {
        let botGUID = store.feishuBotConfig.botTasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalGUID = store.feishuBotConfig.tasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.feishuBotConfig.taskAuthMode == .botTenant, !botGUID.isEmpty {
            return [botGUID]
        }
        return externalGUID.isEmpty ? [] : [externalGUID]
    }

    private func normalizedTasklist(_ tasklistGUID: String?, fallback: String?) -> String? {
        let trimmed = tasklistGUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func isNotFoundMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not found")
            || lower.contains("deleted")
            || message.contains("不存在")
            || message.contains("已删除")
            || message.contains("无效")
    }

    private func makeTaskCandidate(
        from task: [String: Any],
        fallbackGUID: String = "",
        tasklistGUIDs: Set<String> = []
    ) -> FeishuTaskCandidate {
        let assignees = taskAssigneeInfo(from: task)
        return FeishuTaskCandidate(
            guid: textValue(task["guid"]) ?? fallbackGUID,
            summary: textValue(task["summary"]) ?? "",
            completedAt: textValue(task["completed_at"]),
            tasklistGUIDs: tasklistGUIDs,
            assigneeIDs: assignees.ids,
            assigneeNameByID: assignees.nameByID
        )
    }

    private func taskAssigneeInfo(from task: [String: Any]) -> (ids: [String], nameByID: [String: String]) {
        var ids: [String] = []
        var nameByID: [String: String] = [:]
        var seen = Set<String>()

        for member in taskMemberObjects(from: task) {
            guard isAssigneeMember(member), isUserMember(member),
                  let id = firstUserID(in: member) else { continue }
            if seen.insert(id).inserted {
                ids.append(id)
            }
            if let name = firstUserName(in: member) {
                nameByID[id] = name
            }
        }

        return (ids, nameByID)
    }

    private func taskMemberObjects(from task: [String: Any]) -> [[String: Any]] {
        for key in ["members", "task_members"] {
            let members = dictionaryArray(from: task[key])
            if !members.isEmpty { return members }
        }
        return []
    }

    private func dictionaryArray(from value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let object = value as? [String: Any] {
            for key in ["items", "list", "members"] {
                let nested = dictionaryArray(from: object[key])
                if !nested.isEmpty { return nested }
            }
        }
        return []
    }

    private func isAssigneeMember(_ member: [String: Any]) -> Bool {
        roleValues(in: member).contains { $0 == "assignee" }
    }

    private func isUserMember(_ member: [String: Any]) -> Bool {
        let types = typeValues(in: member)
        if types.isEmpty {
            return firstUserID(in: member) != nil
        }
        return types.contains { $0 == "user" }
    }

    private func roleValues(in object: [String: Any]) -> [String] {
        textValues(in: object, keys: ["role"])
    }

    private func typeValues(in object: [String: Any]) -> [String] {
        textValues(in: object, keys: ["type", "member_type", "user_type"])
    }

    private func textValues(in object: [String: Any], keys: [String]) -> [String] {
        var result: [String] = []
        for key in keys {
            if let value = textValue(object[key])?.lowercased() {
                result.append(value)
            }
        }
        for key in ["member", "user"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            result.append(contentsOf: textValues(in: nested, keys: keys))
        }
        return result
    }

    private func firstUserID(in object: [String: Any]) -> String? {
        for key in ["id", "open_id", "user_id"] {
            if let value = textValue(object[key]) {
                return value
            }
        }
        for key in ["user", "member"] {
            if let value = textValue(object[key]) {
                return value
            }
            if let nested = object[key] as? [String: Any],
               let value = firstUserID(in: nested) {
                return value
            }
        }
        return nil
    }

    private func firstUserName(in object: [String: Any]) -> String? {
        for key in ["name", "display_name", "localized_name", "name_cn", "name_en", "nickname"] {
            if let value = textValue(object[key]) {
                return value
            }
            if let value = localizedNameValue(object[key]) {
                return value
            }
        }
        for key in ["user", "member"] {
            if let nested = object[key] as? [String: Any],
               let value = firstUserName(in: nested) {
                return value
            }
        }
        return nil
    }

    private func localizedNameValue(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        for key in ["zh_cn", "en_us", "ja_jp", "default", "name"] {
            if let value = textValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private func textValue(_ value: Any?) -> String? {
        let raw: String?
        if let string = value as? String {
            raw = string
        } else if let number = value as? NSNumber {
            raw = number.stringValue
        } else {
            raw = nil
        }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enrichAssigneeNames(in task: FeishuTaskCandidate, store: DataStore, token: String) async -> FeishuTaskCandidate {
        let tasks = await enrichAssigneeNames(in: [task], store: store, token: token)
        return tasks.first ?? task
    }

    private func enrichAssigneeNames(in tasks: [FeishuTaskCandidate], store: DataStore, token: String) async -> [FeishuTaskCandidate] {
        guard !tasks.isEmpty else { return tasks }
        var knownNames = store.feishuBotConfig.feishuUserNameMap
        for task in tasks {
            for (id, name) in task.assigneeNameByID where !id.isEmpty && !name.isEmpty {
                knownNames[id] = name
            }
        }

        var missingIDs: [String] = []
        var seen = Set<String>()
        for task in tasks {
            for id in task.assigneeIDs where knownNames[id] == nil && seen.insert(id).inserted {
                missingIDs.append(id)
            }
        }

        for id in missingIDs {
            if let name = try? await fetchFeishuUserName(userID: id, token: token) {
                knownNames[id] = name
            }
        }

        return tasks.map { task in
            var enriched = task
            for id in task.assigneeIDs {
                if enriched.assigneeNameByID[id] == nil, let name = knownNames[id] {
                    enriched.assigneeNameByID[id] = name
                }
            }
            return enriched
        }
    }

    private func fetchFeishuUserName(userID: String, token: String) async throws -> String? {
        for idType in ["open_id", "user_id"] {
            if let name = try await fetchFeishuUserName(userID: userID, userIDType: idType, token: token, logFailures: false) {
                return name
            }
        }
        DevLog.shared.warn("FeishuTask", "未能解析用户名称 [id=\(userID)]")
        return nil
    }

    private func fetchFeishuUserName(userID: String, userIDType: String, token: String, logFailures: Bool) async throws -> String? {
        guard var components = URLComponents(string: "https://open.feishu.cn/open-apis/contact/v3/users/\(userID)") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "user_id_type", value: userIDType)]
        guard let url = components.url else {
            throw FeishuTaskServiceError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard status == 200 else {
            if status == 401 { throw FeishuTaskServiceError.unauthorized }
            if logFailures {
                DevLog.shared.warn("FeishuTask", "读取用户名称失败 [id=\(userID), idType=\(userIDType), status=\(status), body=\(body.prefix(200))]")
            }
            return nil
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = payload["code"] as? Int, code != 0 {
            let msg = payload["msg"] as? String ?? "读取用户名称失败"
            if code == 99991663 || code == 99991664 { throw FeishuTaskServiceError.unauthorized }
            if logFailures {
                DevLog.shared.warn("FeishuTask", "读取用户名称返回错误 [id=\(userID), idType=\(userIDType), code=\(code), msg=\(msg)]")
            }
            return nil
        }
        guard let dataObj = payload["data"] as? [String: Any] else { return nil }
        let user = dataObj["user"] as? [String: Any] ?? dataObj
        return firstUserName(in: user)
    }

    func createTaskForIssue(store: DataStore, issue: TrackedIssue) async throws -> FeishuTaskCandidate {
        let token = try await tenantAccessToken(store: store)
        let collaboratorOpenID = store.feishuBotConfig.taskDefaultCollaboratorOpenID.trimmingCharacters(in: .whitespacesAndNewlines)
        let tasklistGUID = try await ensureBotTasklist(store: store, token: token, collaboratorOpenID: collaboratorOpenID)
        var task = try await createTask(summary: issue.title, tasklistGUID: tasklistGUID, collaboratorOpenID: collaboratorOpenID, token: token)
        if task.assigneeIDs.isEmpty {
            if let detail = try? await getTaskDetail(guid: task.guid, token: token) {
                task = detail
            }
            if task.assigneeIDs.isEmpty, !collaboratorOpenID.isEmpty {
                task.assigneeIDs = [collaboratorOpenID]
            }
        }
        task = await enrichAssigneeNames(in: task, store: store, token: token)
        DevLog.shared.info("FeishuTask", "已用 Bot 创建飞书任务 [issue=#\(issue.issueNumber), guid=\(task.guid), tasklist=\(tasklistGUID), collaborator=\(collaboratorOpenID.isEmpty ? "未配置" : collaboratorOpenID)]")
        return task
    }

    private func ensureBotTasklist(store: DataStore, token: String, collaboratorOpenID: String) async throws -> String {
        let existing = store.feishuBotConfig.botTasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return existing }
        let name = store.feishuBotConfig.botTasklistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "TicTracker Issues"
            : store.feishuBotConfig.botTasklistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let guid = try await createTasklist(name: name, collaboratorOpenID: collaboratorOpenID, token: token)
        store.updateBotTasklistGUID(guid)
        DevLog.shared.info("FeishuTask", "已创建 Bot 专用任务清单 [name=\(name), guid=\(guid)]")
        return guid
    }

    func deleteBotTasklist(store: DataStore) async throws {
        let tasklistGUID = store.feishuBotConfig.botTasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tasklistGUID.isEmpty else { throw FeishuTaskServiceError.notConfigured }
        let token = try await tenantAccessToken(store: store)
        try await deleteTasklist(guid: tasklistGUID, token: token)
        store.updateBotTasklistGUID("")
        DevLog.shared.info("FeishuTask", "已删除 Bot 专用任务清单 [guid=\(tasklistGUID)]")
    }

    func deleteVisibleTasklist(store: DataStore, guid: String) async throws {
        let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeishuTaskServiceError.notConfigured }
        let token = try await tenantAccessToken(store: store)
        try await deleteTasklist(guid: trimmed, token: token)
        if store.feishuBotConfig.botTasklistGUID == trimmed {
            store.updateBotTasklistGUID("")
        }
        DevLog.shared.info("FeishuTask", "已删除任务清单 [guid=\(trimmed)]")
    }

    private func deleteTasklist(guid: String, token: String) async throws {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/task/v2/tasklists/\(guid)") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try parseMutationPayload(data: data, response: response, action: "删除 Bot 任务清单")
    }

    private func createTasklist(name: String, collaboratorOpenID: String, token: String) async throws -> String {
        guard var components = URLComponents(string: "https://open.feishu.cn/open-apis/task/v2/tasklists") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "user_id_type", value: "open_id")]
        guard let url = components.url else {
            throw FeishuTaskServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "name": name,
            "user_id_type": "open_id"
        ]
        if !collaboratorOpenID.isEmpty {
            body["members"] = [[
                "id": collaboratorOpenID,
                "role": "editor",
                "type": "user"
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let payload = try parseMutationPayload(data: data, response: response, action: "创建 Bot 任务清单")
        let dataObj = payload["data"] as? [String: Any]
        let tasklistObj = dataObj?["tasklist"] as? [String: Any] ?? dataObj ?? payload
        guard let guid = tasklistObj["guid"] as? String, !guid.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            DevLog.shared.error("FeishuTask", "创建 Bot 任务清单响应缺少 guid [payload=\(body.prefix(300))]")
            throw FeishuTaskServiceError.invalidResponse
        }
        return guid
    }

    private func createTask(summary: String, tasklistGUID: String, collaboratorOpenID: String, token: String) async throws -> FeishuTaskCandidate {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/task/v2/tasks") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "未命名问题" : trimmed
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var requestBody: [String: Any] = [
            "summary": title,
            "can_edit": true,
            "tasklists": [[
                "tasklist_guid": tasklistGUID
            ]]
        ]
        if !collaboratorOpenID.isEmpty {
            requestBody["members"] = [[
                "id": collaboratorOpenID,
                "role": "assignee",
                "type": "user"
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        DevLog.shared.info("FeishuTask", "创建任务请求 [tasklist=\(tasklistGUID), title=\(title)]")

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseTaskMutationResponse(data: data, response: response, action: "创建任务")
    }

    private func addTaskCollaborator(guid: String, openID: String, token: String) async throws {
        guard var components = URLComponents(string: "https://open.feishu.cn/open-apis/task/v2/tasks/\(guid)/add_members") else {
            throw FeishuTaskServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "user_id_type", value: "open_id")]
        guard let url = components.url else {
            throw FeishuTaskServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "members": [[
                "id": openID,
                "type": "user",
                "role": "assignee"
            ]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        _ = try parseMutationPayload(data: data, response: response, action: "添加默认执行者")
    }

    private func parseTaskMutationResponse(data: Data, response: URLResponse, action: String) throws -> FeishuTaskCandidate {
        let payload = try parseMutationPayload(data: data, response: response, action: action)
        let dataObj = payload["data"] as? [String: Any]
        let taskObj = dataObj?["task"] as? [String: Any] ?? dataObj ?? payload
        guard let guid = taskObj["guid"] as? String, !guid.isEmpty else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            DevLog.shared.error("FeishuTask", "\(action)响应缺少 guid [payload=\(body.prefix(300))]")
            throw FeishuTaskServiceError.invalidResponse
        }
        return makeTaskCandidate(from: taskObj, fallbackGUID: guid)
    }

    private func parseMutationPayload(data: Data, response: URLResponse, action: String) throws -> [String: Any] {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard status == 200 else {
            DevLog.shared.error("FeishuTask", "\(action)失败 [status=\(status), body=\(body.prefix(300))]")
            if status == 401 { throw FeishuTaskServiceError.unauthorized }
            if status == 403 { throw FeishuTaskServiceError.permissionDenied("Bot / 应用身份无权\(action)，请确认应用任务权限已开通并发布") }
            throw FeishuTaskServiceError.invalidResponse
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeishuTaskServiceError.invalidResponse
        }
        if let code = payload["code"] as? Int, code != 0 {
            let msg = payload["msg"] as? String ?? body
            DevLog.shared.error("FeishuTask", "\(action)返回错误 [code=\(code), msg=\(msg)]")
            if code == 99991663 || code == 99991664 { throw FeishuTaskServiceError.unauthorized }
            if code == 99991672 || code == 99991661 || msg.lowercased().contains("permission") || msg.contains("权限") {
                throw FeishuTaskServiceError.permissionDenied("Bot / 应用身份无权\(action)，请确认应用任务权限已开通并发布")
            }
            throw FeishuTaskServiceError.server(msg)
        }
        return payload
    }

    func listVisibleTasklistsForPicker(store: DataStore) async throws -> [FeishuVisibleTasklist] {
        let token = try await accessToken(for: store)
        return try await self.listVisibleTasklists(token: token)
    }

    func listBotVisibleTasklists(store: DataStore) async throws -> [FeishuVisibleTasklist] {
        let token = try await tenantAccessToken(store: store)
        return try await self.listVisibleTasklists(token: token)
    }

    private func listVisibleTasklists(token: String) async throws -> [FeishuVisibleTasklist] {
        var pageToken = ""
        var all: [FeishuVisibleTasklist] = []

        while true {
            var components = URLComponents(string: "https://open.feishu.cn/open-apis/task/v2/tasklists")
            components?.queryItems = [URLQueryItem(name: "page_size", value: "50")]
            if !pageToken.isEmpty {
                components?.queryItems?.append(URLQueryItem(name: "page_token", value: pageToken))
            }
            guard let url = components?.url else {
                throw FeishuTaskServiceError.invalidResponse
            }

            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DevLog.shared.error("FeishuTask", "拉取可见清单失败 [status=\(status), body=\(body.prefix(300))]")
                if status == 401 { throw FeishuTaskServiceError.unauthorized }
                throw FeishuTaskServiceError.invalidResponse
            }
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let code = payload["code"] as? Int, code != 0 {
                let msg = payload["msg"] as? String ?? "拉取可见清单失败"
                DevLog.shared.error("FeishuTask", "可见清单返回错误 [code=\(code), msg=\(msg)]")
                if code == 99991663 || code == 99991664 { throw FeishuTaskServiceError.unauthorized }
                if code == 99991672 || code == 99991661 || msg.lowercased().contains("permission") || msg.contains("权限") {
                    throw FeishuTaskServiceError.permissionDenied("Bot / 应用身份无权读取该任务清单，请确认应用已被加入清单协作或收到任务分享")
                }
                throw FeishuTaskServiceError.server(msg)
            }
            guard let dataObj = payload["data"] as? [String: Any] else {
                throw FeishuTaskServiceError.invalidResponse
            }
            let items = dataObj["items"] as? [[String: Any]] ?? []
            all += items.compactMap { item in
                guard let guid = item["guid"] as? String, !guid.isEmpty else { return nil }
                return FeishuVisibleTasklist(
                    guid: guid,
                    name: item["name"] as? String ?? guid
                )
            }
            let hasMore = dataObj["has_more"] as? Bool ?? false
            let nextPageToken = dataObj["page_token"] as? String ?? ""
            if !hasMore || nextPageToken.isEmpty { break }
            pageToken = nextPageToken
        }

        return all
    }

    private func listTasklistTasks(tasklistGUID: String, token: String) async throws -> [FeishuTaskCandidate] {
        var pageToken = ""
        var all: [FeishuTaskCandidate] = []

        while true {
            var components = URLComponents(string: "https://open.feishu.cn/open-apis/task/v2/tasklists/\(tasklistGUID)/tasks")
            components?.queryItems = [
                URLQueryItem(name: "page_size", value: "50")
            ]
            if !pageToken.isEmpty {
                components?.queryItems?.append(URLQueryItem(name: "page_token", value: pageToken))
            }
            guard let url = components?.url else {
                throw FeishuTaskServiceError.invalidResponse
            }

            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DevLog.shared.error("FeishuTask", "读取任务清单失败 [tasklist=\(tasklistGUID), status=\(status), body=\(body.prefix(300))]")
                if status == 401 { throw FeishuTaskServiceError.unauthorized }
                throw FeishuTaskServiceError.invalidResponse
            }
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let code = payload["code"] as? Int, code != 0 {
                let msg = payload["msg"] as? String ?? "读取任务清单失败"
                DevLog.shared.error("FeishuTask", "任务清单返回错误 [tasklist=\(tasklistGUID), code=\(code), msg=\(msg)]")
                if code == 99991663 || code == 99991664 { throw FeishuTaskServiceError.unauthorized }
                if code == 99991672 || code == 99991661 || msg.lowercased().contains("permission") || msg.contains("权限") {
                    throw FeishuTaskServiceError.permissionDenied("Bot / 应用身份无权读取该任务清单，请确认应用已被加入清单协作或收到任务分享")
                }
                throw FeishuTaskServiceError.server(msg)
            }
            guard let dataObj = payload["data"] as? [String: Any] else {
                DevLog.shared.error("FeishuTask", "任务清单响应缺少 data 字段 [tasklist=\(tasklistGUID), payload=\(payload)]")
                throw FeishuTaskServiceError.invalidResponse
            }
            let items = dataObj["items"] as? [[String: Any]] ?? []
            all += items.map { item in
                makeTaskCandidate(from: item, tasklistGUIDs: [tasklistGUID])
            }.filter { !$0.guid.isEmpty }

            let hasMore = dataObj["has_more"] as? Bool ?? false
            let nextPageToken = dataObj["page_token"] as? String ?? ""
            if !hasMore || nextPageToken.isEmpty {
                break
            }
            pageToken = nextPageToken
        }

        return all
    }
}
