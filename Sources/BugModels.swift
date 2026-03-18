import Foundation

enum BugStatus: String, Codable, Sendable, CaseIterable {
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

struct BugEntry: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var title: String
    var dateKey: String = ""
    var createdAt: Date = Date()
    var status: BugStatus = .pending
    var assignee: String?
    var jiraKey: String?
    var note: String?
    var fixedAt: Date?

    // Migration: decode legacy isFixed field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        dateKey = try container.decode(String.self, forKey: .dateKey)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        assignee = try container.decodeIfPresent(String.self, forKey: .assignee)
        jiraKey = try container.decodeIfPresent(String.self, forKey: .jiraKey)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        fixedAt = try container.decodeIfPresent(Date.self, forKey: .fixedAt)

        if let s = try? container.decode(BugStatus.self, forKey: .status) {
            status = s
        } else if let isFixed = try? container.decode(Bool.self, forKey: .isFixed) {
            status = isFixed ? .fixed : .pending
        } else {
            status = .pending
        }
    }

    init(title: String) {
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, dateKey, createdAt, status, assignee, jiraKey, note, fixedAt
        case isFixed // legacy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(dateKey, forKey: .dateKey)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(jiraKey, forKey: .jiraKey)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(fixedAt, forKey: .fixedAt)
    }
}
