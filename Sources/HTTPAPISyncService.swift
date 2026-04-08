import Foundation

final class HTTPAPISyncService: CloudSyncService, Sendable {
    private let serverURL: String
    private let token: String

    init(serverURL: String, token: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
    }

    private var syncURL: URL {
        get throws {
            guard let url = URL(string: "\(serverURL)/sync") else {
                throw SyncError.invalidResponse("无效的 API URL")
            }
            return url
        }
    }

    private func authHeader() -> String { "Bearer \(token)" }

    func upload(_ data: Data) async throws {
        var request = URLRequest(url: try syncURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.uploadFailed("API 上传失败：无效响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw SyncError.uploadFailed("API 上传失败: HTTP \(http.statusCode) \(body)")
        }
    }

    func download() async throws -> Data? {
        var request = URLRequest(url: try syncURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.downloadFailed("API 下载失败: HTTP \(http.statusCode)")
        }
        return data
    }

    func testConnection() async throws {
        var request = URLRequest(url: try syncURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode != 401 else {
            throw SyncError.notAvailable("API 认证失败，请检查 Token")
        }
    }
}
