import Foundation

final class WebDAVSyncService: CloudSyncService, Sendable {
    private let serverURL: String
    private let username: String
    private let password: String
    private static let filename = "tictacker-sync.json"

    init(serverURL: String, username: String, password: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.username = username
        self.password = password
    }

    private var fileURL: URL {
        get throws {
            guard let url = URL(string: "\(serverURL)/\(Self.filename)") else {
                throw SyncError.invalidResponse("无效的 WebDAV URL")
            }
            return url
        }
    }

    private func authHeader() -> String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    func upload(_ data: Data) async throws {
        var request = URLRequest(url: try fileURL, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncError.uploadFailed("WebDAV 上传失败")
        }
    }

    func download() async throws -> Data? {
        var request = URLRequest(url: try fileURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.downloadFailed("WebDAV 下载失败: HTTP \(http.statusCode)")
        }
        return data
    }

    func testConnection() async throws {
        var request = URLRequest(url: try fileURL, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode != 401 else {
            throw SyncError.notAvailable("WebDAV 认证失败，请检查用户名和密码")
        }
    }
}
