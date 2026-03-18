import Foundation

enum ProjectIssueStatus: String, Codable, Sendable, CaseIterable {
    case pending = "未解决"
    case resolved = "已解决"

    var icon: String {
        switch self {
        case .pending: return "exclamationmark.circle"
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
