import Foundation

// MARK: - Protocol

protocol CloudSyncService: Sendable {
    func upload(_ data: Data) async throws
    func download() async throws -> Data?
    func testConnection() async throws
}

// MARK: - Config

struct SyncConfig: Codable {
    enum Backend: String, Codable, CaseIterable {
        case iCloud = "iCloud"
        case webDAV = "WebDAV"
        case httpAPI = "HTTP API"
    }

    var enabled: Bool = false
    var backend: Backend = .iCloud
    var intervalMinutes: Int = 30
    var lastSyncDate: Date? = nil
    var serverURL: String = ""
    var username: String = ""  // WebDAV Basic Auth
}

// MARK: - Status

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case error(String)
}

// MARK: - SyncManager

@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    var config: SyncConfig {
        didSet { saveConfig() }
    }
    var status: SyncStatus = .idle

    private var periodicTask: Task<Void, Never>?
    private static let configKey = "syncConfig"
    private static let keychainService = "com.tictracker.sync"

    private var keychainAccount: String {
        "credential-\(config.backend.rawValue)"
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(SyncConfig.self, from: data) {
            config = decoded
        } else {
            config = SyncConfig()
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: - Credential (Keychain)

    func saveCredential(_ value: String) {
        if let data = value.data(using: .utf8) {
            KeychainHelper.save(service: Self.keychainService, account: keychainAccount, data: data)
        }
    }

    func loadCredential() -> String {
        guard let data = KeychainHelper.load(service: Self.keychainService, account: keychainAccount) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Service Factory

    func makeService() -> CloudSyncService? {
        switch config.backend {
        case .iCloud:
            return iCloudSyncService()
        case .webDAV:
            guard !config.serverURL.isEmpty else { return nil }
            return WebDAVSyncService(serverURL: config.serverURL, username: config.username, password: loadCredential())
        case .httpAPI:
            guard !config.serverURL.isEmpty else { return nil }
            return HTTPAPISyncService(serverURL: config.serverURL, token: loadCredential())
        }
    }

    // MARK: - Sync

    func sync(store: DataStore) async {
        guard config.enabled, let service = makeService() else { return }
        if case .syncing = status { return }  // 防止并发

        status = .syncing
        do {
            guard let localData = store.exportSyncData() else {
                status = .error("导出数据失败")
                return
            }

            if let remoteData = try await service.download() {
                // 比较 lastModified，取较新的
                let localTS = extractTimestamp(from: localData)
                let remoteTS = extractTimestamp(from: remoteData)
                if remoteTS > localTS {
                    if store.importSyncData(remoteData) {
                        DevLog.shared.info("Sync", "从云端下载并导入数据")
                    }
                } else if localTS > remoteTS {
                    try await service.upload(localData)
                    DevLog.shared.info("Sync", "本地数据更新，已上传")
                } else {
                    DevLog.shared.info("Sync", "本地与云端数据一致，无需同步")
                }
            } else {
                // 远端无数据，直接上传
                try await service.upload(localData)
                DevLog.shared.info("Sync", "首次上传数据到云端")
            }

            config.lastSyncDate = Date()
            status = .success(Date())
        } catch {
            DevLog.shared.error("Sync", "同步失败: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    func testConnection() async -> Result<Void, Error> {
        guard let service = makeService() else {
            return .failure(NSError(domain: "Sync", code: 0, userInfo: [NSLocalizedDescriptionKey: "配置不完整"]))
        }
        do {
            try await service.testConnection()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Periodic Sync

    func startPeriodicSync(store: DataStore) {
        stopPeriodicSync()
        guard config.enabled, config.intervalMinutes > 0 else { return }
        let interval = TimeInterval(config.intervalMinutes * 60)
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.sync(store: store)
            }
        }
    }

    func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Helpers

    private func extractTimestamp(from data: Data) -> Date {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["lastModified"] as? TimeInterval else { return .distantPast }
        return Date(timeIntervalSince1970: ts)
    }
}
