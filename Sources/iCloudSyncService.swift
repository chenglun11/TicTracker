import Foundation

/// 通过 iCloud Drive 文件同步（无需 entitlement，只需用户登录 iCloud）
final class iCloudSyncService: CloudSyncService, @unchecked Sendable {
    private static let filename = "tictacker-sync.json"
    private static let containerName = "TicTracker"

    /// iCloud Drive 目录：~/Library/Mobile Documents/com~apple~CloudDocs/TicTracker/
    private var containerURL: URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            // fallback: 直接用 iCloud Drive 公共目录
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(Self.containerName)")
            return path
        }
        return base.appendingPathComponent("Documents/\(Self.containerName)")
    }

    private var fileURL: URL? {
        guard let dir = containerURL else { return nil }
        return dir.appendingPathComponent(Self.filename)
    }

    func upload(_ data: Data) async throws {
        guard let dir = containerURL, let url = fileURL else {
            throw SyncError.notAvailable("无法访问 iCloud Drive 目录")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func download() async throws -> Data? {
        guard let url = fileURL else {
            throw SyncError.notAvailable("无法访问 iCloud Drive 目录")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func testConnection() async throws {
        guard let dir = containerURL else {
            throw SyncError.notAvailable("无法访问 iCloud Drive 目录")
        }
        // 尝试创建目录验证可写
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw SyncError.notAvailable("iCloud Drive 目录不可写，请检查 iCloud 是否已登录")
        }
    }
}

enum SyncError: LocalizedError {
    case uploadFailed(String)
    case downloadFailed(String)
    case notAvailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg), .downloadFailed(let msg),
             .notAvailable(let msg), .invalidResponse(let msg): return msg
        }
    }
}
