import Foundation

struct AuthoritativeSyncSnapshot: Sendable {
    let data: Data
    let revision: Int64
}

protocol AuthoritativeSyncService: CloudSyncService {
    func downloadSnapshot() async throws -> AuthoritativeSyncSnapshot?
    func uploadSnapshot(_ data: Data, expectedRevision: Int64) async throws -> Int64
}

struct IssueDeltaEvent: Decodable, Sendable {
    let cursor: Int64
    let type: String
    let entityId: String
    let entityRevision: Int64
    let payload: TrackedIssue?
    let operationId: String?

    private enum CodingKeys: String, CodingKey { case cursor, type, entityId, entityRevision, payload, operationId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(Int64.self, forKey: .cursor)
        type = try container.decode(String.self, forKey: .type)
        entityId = try container.decode(String.self, forKey: .entityId)
        entityRevision = try container.decode(Int64.self, forKey: .entityRevision)
        payload = try? container.decode(TrackedIssue.self, forKey: .payload)
        operationId = try? container.decodeIfPresent(String.self, forKey: .operationId)
    }
}

struct IssueDeltaPage: Decodable, Sendable {
    let events: [IssueDeltaEvent]
    let nextCursor: Int64
    let latestCursor: Int64?
    let cursorReset: Bool?
}

enum IssueDeltaSyncError: LocalizedError {
    case conflict(TrackedIssue)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .conflict: "线上 Issue 已有新版本"
        case .rejected(let message): message
        }
    }
}

protocol IssueDeltaSyncService: AuthoritativeSyncService {
    func downloadIssueEvents(after cursor: Int64) async throws -> IssueDeltaPage
    func upsertIssue(_ issue: TrackedIssue, baseRevision: Int64, operationID: UUID) async throws -> TrackedIssue
    func deleteIssue(id: String, baseRevision: Int64, operationID: UUID) async throws -> TrackedIssue
}

final class HTTPAPISyncService: IssueDeltaSyncService, Sendable {
    private let serverURL: String
    private let token: String
    private let clientID: String
    private static let clientIDKey = "sync.authoritative.client-id"

    init(serverURL: String, token: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
        if let saved = UserDefaults.standard.string(forKey: Self.clientIDKey), !saved.isEmpty {
            self.clientID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            UserDefaults.standard.set(generated, forKey: Self.clientIDKey)
            self.clientID = generated
        }
    }

    private var syncURL: URL {
        get throws {
            guard let url = URL(string: "\(serverURL)/sync") else {
                throw SyncError.invalidResponse("无效的 API URL")
            }
            try Self.validateSecureURL(url)
            return url
        }
    }

    private func deltaURL(_ path: String) throws -> URL {
        guard let url = URL(string: "\(serverURL)/sync/v2\(path)") else {
            throw SyncError.invalidResponse("无效的增量同步 URL")
        }
        try Self.validateSecureURL(url)
        return url
    }

    private static func validateSecureURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" || isLocalHTTP(url) else {
            throw SyncError.notAvailable("API 同步地址必须使用 HTTPS（本机 localhost/127.0.0.1 除外）")
        }
    }

    private static func isLocalHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func authHeader() -> String { "Bearer \(token)" }

    func upload(_ data: Data) async throws {
        _ = try await uploadSnapshot(data, expectedRevision: 0)
    }

    func uploadSnapshot(_ data: Data, expectedRevision: Int64) async throws -> Int64 {
        var request = URLRequest(url: try syncURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(expectedRevision)\"", forHTTPHeaderField: "If-Match")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.uploadFailed("API 上传失败：无效响应")
        }
        if http.statusCode == 409 {
            let revision = Self.revision(from: http, data: responseData) ?? expectedRevision
            throw SyncError.conflict("线上数据已更新（修订版 \(revision)），请先同步后再提交")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw SyncError.uploadFailed("API 上传失败: HTTP \(http.statusCode) \(body)")
        }
        return Self.revision(from: http, data: responseData) ?? (expectedRevision + 1)
    }

    func download() async throws -> Data? {
        try await downloadSnapshot()?.data
    }

    func downloadSnapshot() async throws -> AuthoritativeSyncSnapshot? {
        var request = URLRequest(url: try syncURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.downloadFailed("API 下载失败: HTTP \(http.statusCode)")
        }
        let revision = Self.revision(from: http, data: data) ?? 0
        return AuthoritativeSyncSnapshot(data: data, revision: revision)
    }

    func testConnection() async throws {
        var request = URLRequest(url: try syncURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode != 401 else {
            throw SyncError.notAvailable("API 认证失败，请检查 Token")
        }
    }

    func downloadIssueEvents(after cursor: Int64) async throws -> IssueDeltaPage {
        var components = URLComponents(url: try deltaURL("/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncError.downloadFailed("增量事件下载失败")
        }
        return try JSONDecoder().decode(IssueDeltaPage.self, from: data)
    }

    func upsertIssue(_ issue: TrackedIssue, baseRevision: Int64, operationID: UUID) async throws -> TrackedIssue {
        var request = URLRequest(url: try deltaURL("/issues/\(issue.syncID)"), timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(issue)
        return try await decodeIssueMutation(request)
    }

    func deleteIssue(id: String, baseRevision: Int64, operationID: UUID) async throws -> TrackedIssue {
        var request = URLRequest(url: try deltaURL("/issues/\(id)"), timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-ID")
        request.setValue("\"\(baseRevision)\"", forHTTPHeaderField: "If-Match")
        request.setValue(operationID.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        return try await decodeIssueMutation(request)
    }

    private func decodeIssueMutation(_ request: URLRequest) async throws -> TrackedIssue {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IssueDeltaSyncError.rejected("增量同步响应无效")
        }
        struct MutationResponse: Decodable { let issue: TrackedIssue }
        if http.statusCode == 409 || http.statusCode == 410 {
            struct ConflictResponse: Decodable { let current: TrackedIssue? }
            if let conflict = try? JSONDecoder().decode(ConflictResponse.self, from: data), let current = conflict.current {
                throw IssueDeltaSyncError.conflict(current)
            }
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw IssueDeltaSyncError.rejected("增量同步失败: HTTP \(http.statusCode) \(body)")
        }
        return try JSONDecoder().decode(MutationResponse.self, from: data).issue
    }

    private static func revision(from response: HTTPURLResponse, data: Data) -> Int64? {
        if let value = response.value(forHTTPHeaderField: "X-Sync-Revision"),
           let revision = Int64(value) {
            return revision
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let revision = object["revision"] as? NSNumber {
            return revision.int64Value
        }
        return nil
    }
}
