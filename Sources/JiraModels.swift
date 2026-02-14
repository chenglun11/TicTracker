import Foundation

struct JiraConfig: Codable, Sendable {
    var serverURL: String = ""
    var username: String = ""
    var jql: String = "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
    var pollingInterval: Int = 10
    var enabled: Bool = false
    var showInMenuBar: Bool = true
    var deptMapping: [String: String] = [:]  // issueKey → department name

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        jql = try c.decodeIfPresent(String.self, forKey: .jql) ?? "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
        pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 10
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        deptMapping = try c.decodeIfPresent([String: String].self, forKey: .deptMapping) ?? [:]
    }
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
