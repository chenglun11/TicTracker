import Foundation

enum ProjectIssueStatus: String, Codable, Sendable, CaseIterable {
    case pending = "待处理"
    case resolved = "已修复"

    var icon: String {
        switch self {
        case .pending: return "ant.circle"
        case .resolved: return "checkmark.circle.fill"
        }
    }
}

struct ProjectIssue: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var title: String
    var department: String
    var dateKey: String = ""
    var createdAt: Date = Date()
    var status: ProjectIssueStatus = .pending
    var note: String?
    var resolvedAt: Date?

    init(title: String, department: String) {
        self.title = title
        self.department = department
    }
}
