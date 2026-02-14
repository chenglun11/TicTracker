import Foundation

enum JiraAuthMode: String, Codable, Sendable, CaseIterable {
    case password   // Basic Auth: username + password
    case pat        // Personal Access Token (Bearer)
}

enum JiraMappingField: String, Codable, Sendable, CaseIterable {
    case issueType = "issuetype"
    case priority = "priority"
    case status = "status"
    case keyPrefix = "keyPrefix"

    var label: String {
        switch self {
        case .issueType: return "类型"
        case .priority: return "优先级"
        case .status: return "状态"
        case .keyPrefix: return "Key前缀"
        }
    }
}

struct JiraMappingRule: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var field: JiraMappingField
    var value: String       // e.g. "Bug", "High", "PROJ"
    var department: String  // target department name
}

struct JiraConfig: Codable, Sendable {
    var serverURL: String = ""
    var username: String = ""
    var authMode: JiraAuthMode = .password
    var jql: String = "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
    var pollingInterval: Int = 10
    var pollingStartHour: Int = 9
    var pollingEndHour: Int = 18
    var enabled: Bool = false
    var showInMenuBar: Bool = true
    var deptMapping: [String: String] = [:]  // legacy: issueKey → department name
    var mappingRules: [JiraMappingRule] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMode = try c.decodeIfPresent(JiraAuthMode.self, forKey: .authMode) ?? .password
        jql = try c.decodeIfPresent(String.self, forKey: .jql) ?? "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"
        pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 10
        pollingStartHour = try c.decodeIfPresent(Int.self, forKey: .pollingStartHour) ?? 9
        pollingEndHour = try c.decodeIfPresent(Int.self, forKey: .pollingEndHour) ?? 18
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
        deptMapping = try c.decodeIfPresent([String: String].self, forKey: .deptMapping) ?? [:]
        mappingRules = try c.decodeIfPresent([JiraMappingRule].self, forKey: .mappingRules) ?? []
    }

    func matchedDepartment(for issue: JiraIssue) -> String? {
        // New rules take priority
        for rule in mappingRules {
            let fieldValue: String?
            switch rule.field {
            case .issueType: fieldValue = issue.issueType
            case .priority: fieldValue = issue.priority
            case .status: fieldValue = issue.status
            case .keyPrefix: fieldValue = String(issue.key.prefix(while: { $0 != "-" }))
            }
            if let fv = fieldValue, fv.localizedCaseInsensitiveCompare(rule.value) == .orderedSame {
                return rule.department
            }
        }
        // Fallback to legacy per-issue mapping
        if let dept = deptMapping[issue.key], !dept.isEmpty {
            return dept
        }
        return nil
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
