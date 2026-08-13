import SwiftUI
import CryptoKit

func stableLocalUUID(for remoteID: String) -> UUID {
    let digest = SHA256.hash(data: Data(remoteID.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    return UUID(uuidString: value) ?? UUID()
}

private func parseFlexibleIssueDate(_ value: String) -> Date? {
    if let seconds = Double(value) {
        return Date(timeIntervalSince1970: seconds)
    }
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: value) { return date }
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

private func decodeFlexibleIssueDate<K: CodingKey>(
    from container: KeyedDecodingContainer<K>,
    forKey key: K
) -> Date? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
        // Foundation's default Date Codable format is seconds since 2001-01-01.
        return Date(timeIntervalSinceReferenceDate: value)
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return parseFlexibleIssueDate(value)
    }
    return nil
}

enum IssueType: String, Codable, Sendable, CaseIterable {
    case bug = "Bug"
    case hotfix = "Feature"
    case issue = "Support"

    var icon: String {
        switch self {
        case .bug: return "exclamationmark.triangle.fill"
        case .hotfix: return "star.fill"
        case .issue: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .bug: return .orange
        case .hotfix: return .blue
        case .issue: return .purple
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Hotfix", "Feat", "Feature": self = .hotfix
        case "问题", "Support": self = .issue
        default: self = IssueType(rawValue: raw) ?? .bug
        }
    }
}

enum IssueStatus: String, Codable, Sendable, CaseIterable {
    case pending = "待处理"
    case inProgress = "处理中"
    case testing = "测试中"
    case pendingAcceptance = "待验收"
    case scheduled = "已排期"
    case observing = "观测中"
    case fixed = "已修复"
    case ignored = "已忽略"

    /// 稳定的 case 名称字符串，用于序列化/映射匹配（不依赖 String(describing:)）
    var caseName: String {
        switch self {
        case .pending: return "pending"
        case .inProgress: return "inProgress"
        case .testing: return "testing"
        case .pendingAcceptance: return "pendingAcceptance"
        case .scheduled: return "scheduled"
        case .observing: return "observing"
        case .fixed: return "fixed"
        case .ignored: return "ignored"
        }
    }

    /// 通过 caseName 查找对应的 IssueStatus
    static func fromCaseName(_ name: String) -> IssueStatus? {
        allCases.first { $0.caseName == name }
    }

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .testing: return "testtube.2"
        case .pendingAcceptance: return "checkmark.seal"
        case .scheduled: return "calendar.badge.clock"
        case .observing: return "eye"
        case .fixed: return "checkmark.circle.fill"
        case .ignored: return "minus.circle.fill"
        }
    }

    var isResolved: Bool {
        self == .fixed || self == .ignored
    }
}

extension TrackedIssue {
    var effectiveStatus: IssueStatus {
        guard source == .linear else { return status }
        // 待验收是用户或 Linear 映射明确推进到的本地阶段；Linear 会把
        // 多个自定义工作流状态统一标为 started，不能再把它降级成“处理中”。
        if status == .pendingAcceptance { return .pendingAcceptance }
        if let type = linearStateType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !type.isEmpty {
            switch type {
            case "completed": return .fixed
            case "canceled": return .ignored
            case "started": return .inProgress
            case "triage", "backlog", "unstarted": return .pending
            default: break
            }
        }
        if let name = linearStateName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty {
            switch name {
            case "done", "completed": return .fixed
            case "canceled", "cancelled": return .ignored
            case "in progress", "started": return .inProgress
            case "backlog", "todo", "to do", "triage", "unstarted": return .pending
            default: break
            }
        }
        return status
    }

    var isEffectivelyResolved: Bool {
        effectiveStatus.isResolved
    }

    var displayStatusName: String {
        if source == .linear,
           let name = linearStateName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return effectiveStatus.rawValue
    }

    var displayStatusHelpText: String {
        guard displayStatusName != status.rawValue else { return status.rawValue }
        return "\(displayStatusName)（本地：\(status.rawValue)）"
    }

    var displayStatusIcon: String {
        effectiveStatus.icon
    }
}

struct IssueComment: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var remoteID: String?
    var syncID: String { remoteID ?? id.uuidString.lowercased() }
    var text: String
    var createdAt: Date = Date()
    /// Jira comment ID for deduplication; nil means local comment
    var jiraCommentId: String?

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, jiraCommentId, jiraCommentID }

    init(id: UUID = UUID(), remoteID: String? = nil, text: String, createdAt: Date = Date(), jiraCommentId: String? = nil) {
        self.id = id
        self.remoteID = remoteID
        self.text = text
        self.createdAt = createdAt
        self.jiraCommentId = jiraCommentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString.lowercased()
        if let uuid = UUID(uuidString: rawID) {
            id = uuid
            remoteID = nil
        } else {
            id = stableLocalUUID(for: rawID)
            remoteID = rawID
        }
        text = try container.decode(String.self, forKey: .text)
        createdAt = decodeFlexibleIssueDate(from: container, forKey: .createdAt) ?? Date()
        jiraCommentId = (try? container.decodeIfPresent(String.self, forKey: .jiraCommentId))
            ?? (try? container.decodeIfPresent(String.self, forKey: .jiraCommentID))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(syncID, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(jiraCommentId, forKey: .jiraCommentId)
    }
}

struct TeamMember: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

enum IssueSource: String, Codable, Sendable, CaseIterable {
    case manual = "手动"
    case web = "Web"
    case jira = "Jira"
    case meta = "Meta Direct Support"
    case feishu = "飞书任务"
    case linear = "Linear"

    var isReadOnly: Bool {
        false
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "飞书文档", "飞书任务":
            self = .feishu
        case "Web":
            self = .web
        default:
            self = IssueSource(rawValue: raw) ?? .manual
        }
    }
}

enum DiaryBadge: String, Codable, Sendable, CaseIterable {
    case auto = "自动"
    case new = "NEW"
    case upd = "UPD"
    case none = "无"
}

struct TrackedIssue: Identifiable, Codable, Sendable {
    var revision: Int64 = 1
    var id: UUID = UUID()
    var remoteID: String? = nil
    var syncID: String { remoteID ?? id.uuidString.lowercased() }
    var issueNumber: Int = 0            // 人类可读序号，如 #1, #2, #3
    var type: IssueType = .bug
    var title: String
    var dateKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date? = nil
    var updatedBy: String? = nil
    var deletedAt: String? = nil
    var diaryBadge: DiaryBadge = .auto
    var status: IssueStatus = .pending
    var source: IssueSource = .manual
    var assignee: String?
    var jiraKey: String?
    var ticketURL: String?   // 外部工单链接（Meta Direct Support 等）
    var department: String?
    var comments: [IssueComment] = []
    var resolvedAt: Date?
    var hasDevActivity: Bool = false     // 检测到 GitLab bot 等开发活动
    var isEscalated: Bool = false        // Meta Support 是否已 Escalate
    var feishuTaskGuid: String?          // 对应飞书任务 GUID（新 issue 自动创建）
    var feishuTaskSummary: String?       // 飞书任务标题快照
    var feishuTaskCompletedAt: String?   // 飞书任务完成时间，原样保存
    var feishuTasklistGuids: [String] = [] // 飞书任务所属清单 GUID
    var feishuTaskAssigneeIds: [String] = [] // 飞书任务负责人 ID
    var linearIssueId: String?           // Linear issue UUID
    var linearKey: String?               // Linear issue identifier (如 LIN-123)
    var linearUrl: String?               // Linear issue URL
    var linearProjectId: String?         // Linear project UUID
    var linearProjectName: String?       // Linear project name
    var linearTeamId: String?            // Linear team UUID
    var linearTeamName: String?          // Linear team name
    var linearAssignee: String?          // Linear 当前负责人名称，用于变更检测
    var linearCreator: String?           // Linear 创建人名称
    var linearStateName: String?         // Linear 原始状态名
    var linearStateType: String?         // Linear 状态类型
    var linearCreatedAt: String?         // Linear 原始创建时间
    var linearUpdatedAt: String?         // Linear 原始更新时间
    var followers: [String] = []         // 关注人列表（本地成员名）
    var reporterId: String?              // 本地提交人 ID
    var reporterName: String?            // 本地提交人名称
    var reportedAt: Date?                // 本地提交时间
    var issueTags: [String] = []         // 本地标签，用于工作台筛选和日报重点分组

    init(title: String, type: IssueType = .bug) {
        self.title = title
        self.type = type
    }

    // MARK: - Custom Codable for migration

    private enum CodingKeys: String, CodingKey {
        case revision, id, issueNumber, type, title, dateKey, createdAt, updatedAt, updatedBy, deletedAt, diaryBadge, status, source, assignee, jiraKey, ticketURL, department, comments, resolvedAt, hasDevActivity, isEscalated
        case feishuTaskGuid, feishuTaskSummary, feishuTaskCompletedAt, feishuTasklistGuids, feishuTaskAssigneeIds
        case linearIssueId, linearKey, linearUrl, linearProjectId, linearProjectName, linearTeamId, linearTeamName, linearAssignee, linearCreator, linearStateName, linearStateType, linearCreatedAt, linearUpdatedAt, followers
        case reporterId, reporterName, reportedAt, issueTags
        case note       // legacy single-note field
        case isFixed    // legacy BugEntry field
        case fixedAt    // legacy BugEntry field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        revision = max((try? container.decodeIfPresent(Int64.self, forKey: .revision)) ?? 1, 1)
        let rawID = try container.decode(String.self, forKey: .id)
        if let uuid = UUID(uuidString: rawID) {
            id = uuid
            remoteID = nil
        } else {
            id = stableLocalUUID(for: rawID)
            remoteID = rawID
        }
        issueNumber = (try? container.decodeIfPresent(Int.self, forKey: .issueNumber)) ?? 0
        title = try container.decode(String.self, forKey: .title)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        createdAt = decodeFlexibleIssueDate(from: container, forKey: .createdAt) ?? Date()
        updatedAt = decodeFlexibleIssueDate(from: container, forKey: .updatedAt)
        updatedBy = try? container.decodeIfPresent(String.self, forKey: .updatedBy)
        deletedAt = try? container.decodeIfPresent(String.self, forKey: .deletedAt)
        diaryBadge = (try? container.decodeIfPresent(DiaryBadge.self, forKey: .diaryBadge)) ?? .auto
        source = (try? container.decodeIfPresent(IssueSource.self, forKey: .source)) ?? .manual
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        jiraKey = try container.decodeIfPresent(String.self, forKey: .jiraKey)
        ticketURL = try container.decodeIfPresent(String.self, forKey: .ticketURL)
        department = try container.decodeIfPresent(String.self, forKey: .department)

        // Auto-fix: if jiraKey is set but source is still manual, correct it
        // Only if ticketURL is empty (to avoid affecting Meta/Feishu tickets)
        if let key = jiraKey, !key.isEmpty, source == .manual, ticketURL == nil || ticketURL?.isEmpty == true {
            source = .jira
        }

        // Comments: decode new format, or migrate from legacy single note
        if let decoded = try? container.decode([IssueComment].self, forKey: .comments) {
            comments = decoded
        } else {
            let legacyNote = try? container.decodeIfPresent(String.self, forKey: .note)
            if let noteText = legacyNote, !noteText.isEmpty {
                comments = [IssueComment(text: noteText, createdAt: createdAt)]
            } else {
                comments = []
            }
        }

        // Determine type
        if let t = try? container.decode(IssueType.self, forKey: .type) {
            type = t
        } else if department != nil && department?.isEmpty == false {
            // Legacy ProjectIssue format: has department, no type
            type = .issue
        } else {
            // Legacy BugEntry format
            type = .bug
        }

        // Determine status - handle all legacy formats
        if let s = try? container.decode(IssueStatus.self, forKey: .status) {
            status = s
        } else if let raw = try? container.decode(String.self, forKey: .status) {
            // Legacy ProjectIssueStatus: "未解决" → pending, "已解决" → fixed
            switch raw {
            case "未解决": status = .pending
            case "已解决": status = .fixed
            default: status = .pending
            }
        } else if let isFixed = try? container.decode(Bool.self, forKey: .isFixed) {
            // Very old BugEntry format with isFixed bool
            status = isFixed ? .fixed : .pending
        } else {
            status = .pending
        }

        // Determine resolvedAt - handle both field names
        if let ra = decodeFlexibleIssueDate(from: container, forKey: .resolvedAt) {
            resolvedAt = ra
        } else if let fa = decodeFlexibleIssueDate(from: container, forKey: .fixedAt) {
            resolvedAt = fa
        } else {
            resolvedAt = nil
        }

        hasDevActivity = (try? container.decodeIfPresent(Bool.self, forKey: .hasDevActivity)) ?? false
        isEscalated = (try? container.decodeIfPresent(Bool.self, forKey: .isEscalated)) ?? false
        feishuTaskGuid = try? container.decodeIfPresent(String.self, forKey: .feishuTaskGuid)
        feishuTaskSummary = try? container.decodeIfPresent(String.self, forKey: .feishuTaskSummary)
        feishuTaskCompletedAt = try? container.decodeIfPresent(String.self, forKey: .feishuTaskCompletedAt)
        feishuTasklistGuids = (try? container.decodeIfPresent([String].self, forKey: .feishuTasklistGuids)) ?? []
        feishuTaskAssigneeIds = (try? container.decodeIfPresent([String].self, forKey: .feishuTaskAssigneeIds)) ?? []
        linearIssueId = try? container.decodeIfPresent(String.self, forKey: .linearIssueId)
        linearKey = try? container.decodeIfPresent(String.self, forKey: .linearKey)
        linearUrl = try? container.decodeIfPresent(String.self, forKey: .linearUrl)
        linearProjectId = try? container.decodeIfPresent(String.self, forKey: .linearProjectId)
        linearProjectName = try? container.decodeIfPresent(String.self, forKey: .linearProjectName)
        linearTeamId = try? container.decodeIfPresent(String.self, forKey: .linearTeamId)
        linearTeamName = try? container.decodeIfPresent(String.self, forKey: .linearTeamName)
        linearAssignee = try? container.decodeIfPresent(String.self, forKey: .linearAssignee)
        linearCreator = try? container.decodeIfPresent(String.self, forKey: .linearCreator)
        linearStateName = try? container.decodeIfPresent(String.self, forKey: .linearStateName)
        linearStateType = try? container.decodeIfPresent(String.self, forKey: .linearStateType)
        linearCreatedAt = try? container.decodeIfPresent(String.self, forKey: .linearCreatedAt)
        linearUpdatedAt = try? container.decodeIfPresent(String.self, forKey: .linearUpdatedAt)
        followers = (try? container.decodeIfPresent([String].self, forKey: .followers)) ?? []
        reporterId = try? container.decodeIfPresent(String.self, forKey: .reporterId)
        reporterName = try? container.decodeIfPresent(String.self, forKey: .reporterName)
        reportedAt = decodeFlexibleIssueDate(from: container, forKey: .reportedAt)
        issueTags = (try? container.decodeIfPresent([String].self, forKey: .issueTags)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(max(revision, 1), forKey: .revision)
        try container.encode(syncID, forKey: .id)
        if issueNumber > 0 {
            try container.encode(issueNumber, forKey: .issueNumber)
        }
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(dateKey, forKey: .dateKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        if diaryBadge != .auto {
            try container.encode(diaryBadge, forKey: .diaryBadge)
        }
        try container.encode(status, forKey: .status)
        if source != .manual {
            try container.encode(source, forKey: .source)
        }
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(jiraKey, forKey: .jiraKey)
        try container.encodeIfPresent(ticketURL, forKey: .ticketURL)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encode(comments, forKey: .comments)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        if hasDevActivity {
            try container.encode(hasDevActivity, forKey: .hasDevActivity)
        }
        if isEscalated {
            try container.encode(isEscalated, forKey: .isEscalated)
        }
        try container.encodeIfPresent(feishuTaskGuid, forKey: .feishuTaskGuid)
        try container.encodeIfPresent(feishuTaskSummary, forKey: .feishuTaskSummary)
        try container.encodeIfPresent(feishuTaskCompletedAt, forKey: .feishuTaskCompletedAt)
        if !feishuTasklistGuids.isEmpty {
            try container.encode(feishuTasklistGuids, forKey: .feishuTasklistGuids)
        }
        if !feishuTaskAssigneeIds.isEmpty {
            try container.encode(feishuTaskAssigneeIds, forKey: .feishuTaskAssigneeIds)
        }
        try container.encodeIfPresent(linearIssueId, forKey: .linearIssueId)
        try container.encodeIfPresent(linearKey, forKey: .linearKey)
        try container.encodeIfPresent(linearUrl, forKey: .linearUrl)
        try container.encodeIfPresent(linearProjectId, forKey: .linearProjectId)
        try container.encodeIfPresent(linearProjectName, forKey: .linearProjectName)
        try container.encodeIfPresent(linearTeamId, forKey: .linearTeamId)
        try container.encodeIfPresent(linearTeamName, forKey: .linearTeamName)
        try container.encodeIfPresent(linearAssignee, forKey: .linearAssignee)
        try container.encodeIfPresent(linearCreator, forKey: .linearCreator)
        try container.encodeIfPresent(linearStateName, forKey: .linearStateName)
        try container.encodeIfPresent(linearStateType, forKey: .linearStateType)
        try container.encodeIfPresent(linearCreatedAt, forKey: .linearCreatedAt)
        try container.encodeIfPresent(linearUpdatedAt, forKey: .linearUpdatedAt)
        if !followers.isEmpty {
            try container.encode(followers, forKey: .followers)
        }
        try container.encodeIfPresent(reporterId, forKey: .reporterId)
        try container.encodeIfPresent(reporterName, forKey: .reporterName)
        try container.encodeIfPresent(reportedAt, forKey: .reportedAt)
        if !issueTags.isEmpty {
            try container.encode(issueTags, forKey: .issueTags)
        }
    }
}
