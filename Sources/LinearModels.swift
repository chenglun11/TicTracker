import Foundation

// MARK: - Linear Config

struct LinearConfig: Codable, Sendable {
    static let keychainTokenKey = "linear_api_token"

    var enabled: Bool = false
    var teamId: String = ""
    var teamName: String = ""
    var selectedTeams: [LinearTeam] = []
    var projectId: String = ""
    var projectName: String = ""
    var importProjects: [LinearProject] = []
    var autoImportCandidates: Bool = false
    var defaultAssigneeId: String = ""
    var defaultAssigneeName: String = ""
    var pollingInterval: Int = 10
    var pollingStartHour: Int = 9
    var pollingEndHour: Int = 18
    var statusMapping: [String: String] = [:]  // Linear state name → IssueStatus caseName
    var assigneeMapping: [String: String] = [:]  // 本地成员名 → Linear user ID
    var labelMapping: [String: String] = [:]  // Linear label name → IssueType rawValue (Bug/Feature/Support)
    var teamMembers: [LinearUser] = []
    var teamLabels: [LinearLabel] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        selectedTeams = try c.decodeIfPresent([LinearTeam].self, forKey: .selectedTeams) ?? []
        if selectedTeams.isEmpty, !teamId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedTeams = [LinearTeam(id: teamId, name: teamName.isEmpty ? teamId : teamName, key: "")]
        }
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        importProjects = try c.decodeIfPresent([LinearProject].self, forKey: .importProjects) ?? []
        if !teamId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            importProjects = importProjects.map { project in
                guard project.teamId == nil else { return project }
                return LinearProject(id: project.id, name: project.name, teamId: teamId, teamName: teamName)
            }
        }
        autoImportCandidates = try c.decodeIfPresent(Bool.self, forKey: .autoImportCandidates) ?? false
        defaultAssigneeId = try c.decodeIfPresent(String.self, forKey: .defaultAssigneeId) ?? ""
        defaultAssigneeName = try c.decodeIfPresent(String.self, forKey: .defaultAssigneeName) ?? ""
        pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 10
        pollingStartHour = try c.decodeIfPresent(Int.self, forKey: .pollingStartHour) ?? 9
        pollingEndHour = try c.decodeIfPresent(Int.self, forKey: .pollingEndHour) ?? 18
        statusMapping = try c.decodeIfPresent([String: String].self, forKey: .statusMapping) ?? [:]
        statusMapping = Self.normalizedStatusMapping(statusMapping)
        assigneeMapping = try c.decodeIfPresent([String: String].self, forKey: .assigneeMapping) ?? [:]
        labelMapping = try c.decodeIfPresent([String: String].self, forKey: .labelMapping) ?? [:]
        teamMembers = try c.decodeIfPresent([LinearUser].self, forKey: .teamMembers) ?? []
        teamLabels = try c.decodeIfPresent([LinearLabel].self, forKey: .teamLabels) ?? []
    }

    static func normalizedStatusName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    static func displayStatusName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedStatusMapping(_ mapping: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var seen = Set<String>()
        for key in mapping.keys.sorted() {
            let displayName = displayStatusName(key)
            let normalizedName = normalizedStatusName(displayName)
            guard !displayName.isEmpty, seen.insert(normalizedName).inserted else { continue }
            if let value = mapping[key], IssueStatus.fromCaseName(value) != nil {
                result[displayName] = value
            }
        }
        return result
    }

    func mappedStatusCase(for linearStateName: String) -> String? {
        let displayName = Self.displayStatusName(linearStateName)
        if let exact = statusMapping[displayName] {
            return exact
        }
        let normalizedName = Self.normalizedStatusName(linearStateName)
        return statusMapping
            .sorted { $0.key < $1.key }
            .first { Self.normalizedStatusName($0.key) == normalizedName }?
            .value
    }

    mutating func setStatusMapping(linearStateName: String, localCase: String?) {
        let displayName = Self.displayStatusName(linearStateName)
        let normalizedName = Self.normalizedStatusName(displayName)
        guard !displayName.isEmpty else { return }
        statusMapping = statusMapping.filter { Self.normalizedStatusName($0.key) != normalizedName }
        if let localCase, !localCase.isEmpty {
            statusMapping[displayName] = localCase
        }
    }

    var configuredImportProjects: [LinearProject] {
        var result: [LinearProject] = []
        var seen = Set<String>()
        func append(_ project: LinearProject?) {
            guard let project else { return }
            let id = project.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(LinearProject(
                id: id,
                name: name.isEmpty ? id : name,
                teamId: project.teamId,
                teamName: project.teamName
            ))
        }
        if !projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(LinearProject(id: projectId, name: projectName, teamId: teamId, teamName: teamName))
        }
        for project in importProjects {
            append(project)
        }
        return result
    }

    var configuredTeams: [LinearTeam] {
        var result: [LinearTeam] = []
        var seen = Set<String>()
        for team in selectedTeams {
            let id = team.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(LinearTeam(id: id, name: team.name.isEmpty ? id : team.name, key: team.key))
        }
        if result.isEmpty, !teamId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(LinearTeam(id: teamId, name: teamName.isEmpty ? teamId : teamName, key: ""))
        }
        return result
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
    var creator: LinearUser?
    var team: LinearTeam?
    var project: LinearProject? = nil
    var labels: [String] = []
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

struct LinearUser: Codable, Sendable, Identifiable {
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
    /// The owning team is persisted for multi-team project subscriptions.
    /// Optional fields keep project entries written by older app versions decodable.
    var teamId: String? = nil
    var teamName: String? = nil
}

struct LinearLabel: Codable, Sendable, Identifiable {
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
