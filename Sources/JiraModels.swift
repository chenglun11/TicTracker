import Foundation

struct JiraConfig: Codable, Sendable {
    var serverURL: String = ""
    var username: String = ""
    var jql: String = "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
    var pollingInterval: Int = 10
    var enabled: Bool = false
}

struct JiraIssue: Codable, Identifiable, Sendable {
    let key: String
    let summary: String
    let status: String
    let statusCategoryKey: String  // "new" / "indeterminate" / "done"
    let priority: String?
    let issueType: String?
    var id: String { key }
}

struct JiraTransition: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}
