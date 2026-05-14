import Foundation

// MARK: - Linear Config

struct LinearConfig: Codable, Sendable {
    static let keychainTokenKey = "linear_api_token"

    var enabled: Bool = false
    var teamId: String = ""
    var teamName: String = ""
    var projectId: String = ""
    var projectName: String = ""
    var defaultAssigneeId: String = ""
    var defaultAssigneeName: String = ""
    var pollingInterval: Int = 10
    var pollingStartHour: Int = 9
    var pollingEndHour: Int = 18
    var statusMapping: [String: String] = [:]  // Linear state name → IssueStatus rawValue

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        defaultAssigneeId = try c.decodeIfPresent(String.self, forKey: .defaultAssigneeId) ?? ""
        defaultAssigneeName = try c.decodeIfPresent(String.self, forKey: .defaultAssigneeName) ?? ""
        pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 10
        pollingStartHour = try c.decodeIfPresent(Int.self, forKey: .pollingStartHour) ?? 9
        pollingEndHour = try c.decodeIfPresent(Int.self, forKey: .pollingEndHour) ?? 18
        statusMapping = try c.decodeIfPresent([String: String].self, forKey: .statusMapping) ?? [:]
    }
}

// MARK: - Linear Issue

struct LinearIssue: Codable, Sendable, Identifiable {
    var id: String
    var identifier: String  // e.g. "LIN-123"
    var title: String
    var description: String?
    var state: LinearState?
    var assignee: LinearUser?
    var url: String
    var createdAt: String?
    var updatedAt: String?
}

// MARK: - Linear State

struct LinearState: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var type: String  // triage, backlog, unstarted, started, completed, canceled
}

// MARK: - Linear Comment

struct LinearComment: Codable, Sendable, Identifiable {
    var id: String
    var body: String
    var createdAt: String?
    var user: LinearUser?
}

// MARK: - Linear User

struct LinearUser: Codable, Sendable {
    var id: String
    var name: String
}

// MARK: - Linear Team

struct LinearTeam: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var key: String
}

// MARK: - Linear Project

struct LinearProject: Codable, Sendable, Identifiable {
    var id: String
    var name: String
}

// MARK: - Linear Error

enum LinearError: String, Sendable {
    case ok = ""
    case unauthorized = "API Token 无效"
    case networkError = "网络连接失败"
    case rateLimited = "请求频率超限"
    case serverError = "Linear 服务器错误"
    case unknown = "未知错误"
}
