import SwiftUI

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

struct IssueComment: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date = Date()
    /// Jira comment ID for deduplication; nil means local comment
    var jiraCommentId: String?
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
    var id: UUID = UUID()
    var issueNumber: Int = 0            // 人类可读序号，如 #1, #2, #3
    var type: IssueType = .bug
    var title: String
    var dateKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date? = nil
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
    var linearAssignee: String?          // Linear 当前负责人名称，用于变更检测
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
        case id, issueNumber, type, title, dateKey, createdAt, updatedAt, diaryBadge, status, source, assignee, jiraKey, ticketURL, department, comments, resolvedAt, hasDevActivity, isEscalated
        case feishuTaskGuid, feishuTaskSummary, feishuTaskCompletedAt, feishuTasklistGuids, feishuTaskAssigneeIds
        case linearIssueId, linearKey, linearUrl, linearProjectId, linearProjectName, linearAssignee, followers
        case reporterId, reporterName, reportedAt, issueTags
        case note       // legacy single-note field
        case isFixed    // legacy BugEntry field
        case fixedAt    // legacy BugEntry field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        issueNumber = (try? container.decodeIfPresent(Int.self, forKey: .issueNumber)) ?? 0
        title = try container.decode(String.self, forKey: .title)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? nil
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
        if let ra = try? container.decodeIfPresent(Date.self, forKey: .resolvedAt) {
            resolvedAt = ra
        } else if let fa = try? container.decodeIfPresent(Date.self, forKey: .fixedAt) {
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
        linearAssignee = try? container.decodeIfPresent(String.self, forKey: .linearAssignee)
        followers = (try? container.decodeIfPresent([String].self, forKey: .followers)) ?? []
        reporterId = try? container.decodeIfPresent(String.self, forKey: .reporterId)
        reporterName = try? container.decodeIfPresent(String.self, forKey: .reporterName)
        reportedAt = try? container.decodeIfPresent(Date.self, forKey: .reportedAt)
        issueTags = (try? container.decodeIfPresent([String].self, forKey: .issueTags)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if issueNumber > 0 {
            try container.encode(issueNumber, forKey: .issueNumber)
        }
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(dateKey, forKey: .dateKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
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
        try container.encodeIfPresent(linearAssignee, forKey: .linearAssignee)
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
