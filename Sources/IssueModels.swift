import SwiftUI

enum IssueType: String, Codable, Sendable, CaseIterable {
    case bug = "Bug"
    case hotfix = "Feat"
    case issue = "问题"

    var icon: String {
        switch self {
        case .bug: return "ladybug.fill"
        case .hotfix: return "star.fill"
        case .issue: return "bolt.fill"
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
        case "Hotfix", "Feat": self = .hotfix
        default: self = IssueType(rawValue: raw) ?? .bug
        }
    }
}

enum IssueStatus: String, Codable, Sendable, CaseIterable {
    case pending = "待处理"
    case inProgress = "处理中"
    case fixed = "已修复"
    case ignored = "已忽略"

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath"
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
}

enum DiaryBadge: String, Codable, Sendable, CaseIterable {
    case auto = "自动"
    case new = "NEW"
    case upd = "UPD"
    case none = "无"
}

struct TrackedIssue: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var type: IssueType = .bug
    var title: String
    var dateKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date? = nil
    var diaryBadge: DiaryBadge = .auto
    var status: IssueStatus = .pending
    var assignee: String?
    var jiraKey: String?
    var department: String?
    var comments: [IssueComment] = []
    var resolvedAt: Date?

    init(title: String, type: IssueType = .bug) {
        self.title = title
        self.type = type
    }

    // MARK: - Custom Codable for migration

    private enum CodingKeys: String, CodingKey {
        case id, type, title, dateKey, createdAt, updatedAt, diaryBadge, status, assignee, jiraKey, department, comments, resolvedAt
        case note       // legacy single-note field
        case isFixed    // legacy BugEntry field
        case fixedAt    // legacy BugEntry field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? nil
        diaryBadge = (try? container.decodeIfPresent(DiaryBadge.self, forKey: .diaryBadge)) ?? .auto
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        jiraKey = try container.decodeIfPresent(String.self, forKey: .jiraKey)
        department = try container.decodeIfPresent(String.self, forKey: .department)

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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(dateKey, forKey: .dateKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        if diaryBadge != .auto {
            try container.encode(diaryBadge, forKey: .diaryBadge)
        }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(jiraKey, forKey: .jiraKey)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encode(comments, forKey: .comments)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
    }
}
