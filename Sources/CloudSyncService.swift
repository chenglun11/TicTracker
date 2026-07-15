import Foundation
import CryptoKit

// MARK: - Protocol

protocol CloudSyncService: Sendable {
    func upload(_ data: Data) async throws
    func download() async throws -> Data?
    func testConnection() async throws
}

enum SyncPayloadPolicy {
    static let currentSchemaVersion = 2
    static let deviceConfigurationKeys: Set<String> = [
        "jiraConfig", "linearConfig", "feishuBotConfig", "aiConfig",
        "hotkeyBindings", "localMCPConfig"
    ]

    static func supportedSchemaVersion(in object: [String: Any]) -> Bool {
        let version = (object["schemaVersion"] as? NSNumber)?.intValue ?? 1
        return (1...currentSchemaVersion).contains(version)
    }

    static func blocksLargeReduction(
        localRecordBuckets: Int,
        remoteRecordBuckets: Int,
        localSupportTotal: Int,
        remoteSupportTotal: Int,
        localIssues: Int,
        remoteIssues: Int,
        localDepartments: Int = 0,
        remoteDepartments: Int = 0,
        localMembers: Int = 0,
        remoteMembers: Int = 0
    ) -> Bool {
        let recordsDropTooLarge = localRecordBuckets > 0 && remoteRecordBuckets * 2 < localRecordBuckets
        let supportDropTooLarge = localSupportTotal > 0 && remoteSupportTotal * 2 < localSupportTotal
        let issuesDropTooLarge = localIssues > 0 && remoteIssues * 2 < localIssues
        let departmentsDropTooLarge = localDepartments > 0 && remoteDepartments * 2 < localDepartments
        let membersDropTooLarge = localMembers > 0 && remoteMembers * 2 < localMembers
        return recordsDropTooLarge || supportDropTooLarge || issuesDropTooLarge || departmentsDropTooLarge || membersDropTooLarge
    }
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
    var webPortalURL: String = ""
    var webDAVServerURL: String = ""
    var webDAVUsername: String = ""
    var httpAPIServerURL: String = ""

    private enum CodingKeys: String, CodingKey {
        case enabled, backend, intervalMinutes, lastSyncDate, serverURL, username, webPortalURL
        case webDAVServerURL, webDAVUsername, httpAPIServerURL
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        backend = try c.decodeIfPresent(Backend.self, forKey: .backend) ?? .iCloud
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
        lastSyncDate = try c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        webPortalURL = try c.decodeIfPresent(String.self, forKey: .webPortalURL) ?? ""
        webDAVServerURL = try c.decodeIfPresent(String.self, forKey: .webDAVServerURL) ?? ""
        webDAVUsername = try c.decodeIfPresent(String.self, forKey: .webDAVUsername) ?? ""
        httpAPIServerURL = try c.decodeIfPresent(String.self, forKey: .httpAPIServerURL) ?? ""

        // Migrate the single legacy endpoint into the backend that owned it.
        if !serverURL.isEmpty {
            if backend == .webDAV, webDAVServerURL.isEmpty {
                webDAVServerURL = serverURL
                webDAVUsername = username
            } else if backend == .httpAPI, httpAPIServerURL.isEmpty {
                httpAPIServerURL = serverURL
            } else if backend == .iCloud {
                if !username.isEmpty, webDAVServerURL.isEmpty {
                    webDAVServerURL = serverURL
                    webDAVUsername = username
                } else if username.isEmpty, httpAPIServerURL.isEmpty {
                    httpAPIServerURL = serverURL
                }
            }
        }
    }

    mutating func persistActiveProfile() {
        switch backend {
        case .iCloud: break
        case .webDAV:
            webDAVServerURL = serverURL
            webDAVUsername = username
        case .httpAPI:
            httpAPIServerURL = serverURL
        }
    }

    mutating func activateProfile(for newBackend: Backend) {
        persistActiveProfile()
        backend = newBackend
        switch newBackend {
        case .iCloud:
            serverURL = ""
            username = ""
        case .webDAV:
            serverURL = webDAVServerURL
            username = webDAVUsername
        case .httpAPI:
            serverURL = httpAPIServerURL
            username = ""
        }
    }
}

// MARK: - Status

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case conflict(String)
    case error(String)
}

struct SyncDataPreview: Sendable {
    let id: UUID
    let remoteExists: Bool
    let localSupportTotal: Int
    let remoteSupportTotal: Int
    let localIssueCount: Int
    let remoteIssueCount: Int
    let localDepartmentCount: Int
    let remoteDepartmentCount: Int
    let localMemberCount: Int
    let remoteMemberCount: Int
    let remoteSchemaVersion: Int

    var summary: String {
        let remoteState = remoteExists ? "远端格式 v\(remoteSchemaVersion)" : "目标端当前为空"
        return "支持计数 \(localSupportTotal) → \(remoteSupportTotal)，可见问题 \(localIssueCount) → \(remoteIssueCount)，部门 \(localDepartmentCount) → \(remoteDepartmentCount)，成员 \(localMemberCount) → \(remoteMemberCount)，\(remoteState)。本机集成配置与 Keychain 不受影响。"
    }
}

private struct PendingRemotePreview {
    let id: UUID
    let destinationKey: String
    let data: Data?
    let revision: Int64?
    let fingerprint: String?
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
    private(set) var issueConflicts: [IssueSyncConflict] = []
    private(set) var pendingIssueOperations: Int = 0
    private(set) var automaticSyncPaused: Bool
    private(set) var lastSyncDirection: String = "尚未同步"

    private var periodicTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var pendingRemotePreview: PendingRemotePreview?
    private static let configKey = "syncConfig"
    private static let keychainService = "com.tictracker.sync"
    private static let automaticSyncPausedKey = "sync.automatic-paused"
    private var credentialCache: [SyncConfig.Backend: String] = [:]
    private var webPortalTokenCache: String?

    var isBusy: Bool {
        if case .syncing = status { return true }
        return false
    }

    private var syncCredentialAccount: String {
        "sync-credential-\(config.backend.rawValue)"
    }

    private let webPortalCredentialAccount = "web-portal-token"

    private init() {
        automaticSyncPaused = UserDefaults.standard.bool(forKey: Self.automaticSyncPausedKey)
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(SyncConfig.self, from: data) {
            config = decoded
        } else {
            config = SyncConfig()
        }
        migrateLegacySyncIdentityIfNeeded()
        if config.backend == .httpAPI, !config.serverURL.isEmpty {
            let state = IssueSyncJournal.shared.state(for: issueSyncServerKey)
            issueConflicts = state.conflicts.sorted { $0.createdAt > $1.createdAt }
            pendingIssueOperations = state.outbox.count
        }
    }

    @discardableResult
    func switchBackend(to backend: SyncConfig.Backend) -> Bool {
        guard backend != config.backend else { return true }
        guard !isBusy else { return false }
        stopPeriodicSync()
        operationGeneration += 1
        pendingRemotePreview = nil
        config.activateProfile(for: backend)
        automaticSyncPaused = true
        UserDefaults.standard.set(true, forKey: Self.automaticSyncPausedKey)
        status = .idle
        lastSyncDirection = "后端已切换，等待选择迁移方向"
        reloadIssueSyncState()
        return true
    }

    func destinationConfigurationDidChange() {
        guard config.enabled else { return }
        stopPeriodicSync()
        operationGeneration += 1
        pendingRemotePreview = nil
        config.persistActiveProfile()
        automaticSyncPaused = true
        UserDefaults.standard.set(true, forKey: Self.automaticSyncPausedKey)
        lastSyncDirection = "连接配置已变化，等待重新确认同步方向"
    }

    func resumeAutomaticSync(store: DataStore) {
        automaticSyncPaused = false
        UserDefaults.standard.set(false, forKey: Self.automaticSyncPausedKey)
        startPeriodicSync(store: store)
    }

    private func reloadIssueSyncState() {
        guard config.backend == .httpAPI else {
            issueConflicts = []
            pendingIssueOperations = 0
            return
        }
        let state = IssueSyncJournal.shared.state(for: issueSyncServerKey)
        updateIssueSyncIndicators(state)
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: - Credential (Keychain)

    func saveCredential(_ value: String) {
        credentialCache[config.backend] = value
        if let data = value.data(using: .utf8) {
            KeychainHelper.save(service: Self.keychainService, account: syncCredentialAccount, data: data)
        }
    }

    func loadCredential() -> String {
        if let cached = credentialCache[config.backend] {
            return cached
        }
        if let data = KeychainHelper.load(service: Self.keychainService, account: syncCredentialAccount) {
            let value = String(data: data, encoding: .utf8) ?? ""
            credentialCache[config.backend] = value
            return value
        }
        if let legacy = KeychainHelper.load(service: Self.keychainService, account: "credential-\(config.backend.rawValue)") {
            let value = String(data: legacy, encoding: .utf8) ?? ""
            credentialCache[config.backend] = value
            return value
        }
        credentialCache[config.backend] = ""
        return ""
    }

    func saveWebPortalToken(_ value: String) {
        webPortalTokenCache = value
        if let data = value.data(using: .utf8) {
            KeychainHelper.save(service: Self.keychainService, account: webPortalCredentialAccount, data: data)
        }
    }

    func loadWebPortalToken() -> String {
        if let cached = webPortalTokenCache {
            return cached
        }
        guard let data = KeychainHelper.load(service: Self.keychainService, account: webPortalCredentialAccount) else {
            webPortalTokenCache = ""
            return ""
        }
        let value = String(data: data, encoding: .utf8) ?? ""
        webPortalTokenCache = value
        return value
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

    func sync(store: DataStore, allowWhilePaused: Bool = false) async {
        guard config.enabled, let service = makeService() else { return }
        guard allowWhilePaused || !automaticSyncPaused else {
            status = .error("切换后端后自动同步已暂停，请先选择迁移方向")
            return
        }
        if case .syncing = status { return }  // 防止并发

        status = .syncing
        do {
            if let authoritativeService = service as? any AuthoritativeSyncService {
                try await syncAuthoritative(store: store, service: authoritativeService)
                config.lastSyncDate = Date()
                status = .success(Date())
                return
            }

            guard let localData = exportData(from: store) else {
                status = .error("导出数据失败")
                return
            }

            guard let localFingerprint = syncFingerprint(localData) else {
                throw SyncError.invalidResponse("无法计算本机同步数据指纹")
            }
            let defaults = UserDefaults.standard
            let baseline = defaults.string(forKey: fileSyncFingerprintKey)
            if let remoteData = try await service.download() {
                guard let remoteFingerprint = syncFingerprint(remoteData) else {
                    throw SyncError.invalidResponse("云端同步文件格式无效")
                }
                guard let baseline else {
                    if localFingerprint == remoteFingerprint {
                        defaults.set(localFingerprint, forKey: fileSyncFingerprintKey)
                        lastSyncDirection = "本机与云端已建立基线"
                    } else {
                        throw SyncError.conflict("目标文件已有数据。请先预览，再明确选择“上传本机数据”或“采用目标端数据”。")
                    }
                    config.lastSyncDate = Date()
                    status = .success(Date())
                    return
                }

                let localChanged = localFingerprint != baseline
                let remoteChanged = remoteFingerprint != baseline
                switch (localChanged, remoteChanged) {
                case (false, false):
                    DevLog.shared.info("Sync", "本机与云端文件一致")
                case (true, false):
                    try await service.upload(localData)
                    defaults.set(localFingerprint, forKey: fileSyncFingerprintKey)
                    lastSyncDirection = "本机 → 云端"
                case (false, true):
                    try importRemoteData(remoteData, into: store, description: "导入云端数据前自动备份")
                    defaults.set(remoteFingerprint, forKey: fileSyncFingerprintKey)
                    lastSyncDirection = "云端 → 本机"
                case (true, true):
                    if localFingerprint == remoteFingerprint {
                        defaults.set(localFingerprint, forKey: fileSyncFingerprintKey)
                    } else {
                        throw SyncError.conflict("本机和云端文件都已修改，已停止自动覆盖。请预览后选择保留哪一端。")
                    }
                }
            } else if baseline == nil {
                try await service.upload(localData)
                defaults.set(localFingerprint, forKey: fileSyncFingerprintKey)
                DevLog.shared.info("Sync", "首次上传数据到云端")
                lastSyncDirection = "本机 → 云端（初始化）"
            } else {
                throw SyncError.conflict("已同步过的目标文件当前不存在，已停止自动重建。请确认后再上传本机数据。")
            }

            config.lastSyncDate = Date()
            status = .success(Date())
        } catch {
            DevLog.shared.error("Sync", "同步失败: \(error.localizedDescription)")
            if case let SyncError.conflict(message) = error {
                status = .conflict(message)
            } else {
                status = .error(error.localizedDescription)
            }
        }
    }

    func uploadCurrentSnapshot(store: DataStore, confirmedPreviewID: UUID? = nil) async throws {
        guard config.enabled, let service = makeService() else {
            throw SyncError.notAvailable("同步配置不完整")
        }
        let generation = operationGeneration
        let destination = syncDestinationKey
        while case .syncing = status {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try ensureOperationIsCurrent(generation: generation, destination: destination)

        status = .syncing
        do {
            guard let localData = exportData(from: store) else {
                throw SyncError.uploadFailed("导出数据失败")
            }
            if let authoritativeService = service as? any AuthoritativeSyncService {
                let issueCheckpoint: Int64?
                if let deltaService = authoritativeService as? any IssueDeltaSyncService {
                    issueCheckpoint = try await captureIssueCheckpoint(service: deltaService)
                    try ensureOperationIsCurrent(generation: generation, destination: destination)
                } else {
                    issueCheckpoint = nil
                }
                let expectedRevision: Int64
                if let confirmedPreviewID {
                    let preview = try await validatedPreview(
                        id: confirmedPreviewID,
                        service: service,
                        generation: generation,
                        destination: destination
                    )
                    expectedRevision = preview.revision ?? 0
                } else if let stored = UserDefaults.standard.object(forKey: authoritativeRevisionKey) as? NSNumber {
                    expectedRevision = stored.int64Value
                } else {
                    expectedRevision = 0
                }
                let revision = try await authoritativeService.uploadSnapshot(localData, expectedRevision: expectedRevision)
                try ensureOperationIsCurrent(generation: generation, destination: destination)
                try recordAuthoritativeBaseline(store: store, revision: revision, excludeIssues: false)
                try recordAuthoritativeBaseline(store: store, revision: revision, excludeIssues: true)
                if let issueCheckpoint {
                    initializeIssueJournal(store: store, cursor: issueCheckpoint)
                }
            } else {
                guard let confirmedPreviewID else {
                    throw SyncError.conflict("文件型目标需要先预览目标端数据，再确认覆盖。")
                }
                _ = try await validatedPreview(
                    id: confirmedPreviewID,
                    service: service,
                    generation: generation,
                    destination: destination
                )
                try await service.upload(localData)
                try ensureOperationIsCurrent(generation: generation, destination: destination)
                guard let fingerprint = syncFingerprint(localData) else {
                    throw SyncError.invalidResponse("无法记录文件同步基线")
                }
                UserDefaults.standard.set(fingerprint, forKey: fileSyncFingerprintKey)
            }
            pendingRemotePreview = nil
            config.lastSyncDate = Date()
            status = .success(Date())
            lastSyncDirection = "本机 → \(config.backend.rawValue)"
            resumeAutomaticSync(store: store)
            DevLog.shared.info("Sync", "已强制上传当前快照")
        } catch {
            DevLog.shared.error("Sync", "强制上传当前快照失败: \(error.localizedDescription)")
            if case let SyncError.conflict(message) = error {
                status = .conflict(message)
            } else {
                status = .error(error.localizedDescription)
            }
            throw error
        }
    }

    func adoptRemoteData(store: DataStore, confirmedPreviewID: UUID) async throws {
        guard config.enabled, let service = makeService() else {
            throw SyncError.notAvailable("同步配置不完整")
        }
        let generation = operationGeneration
        let destination = syncDestinationKey
        if case .syncing = status {
            throw SyncError.notAvailable("另一项同步操作正在进行，请稍后重试")
        }
        status = .syncing
        do {
            let issueCheckpoint: Int64?
            if let deltaService = service as? any IssueDeltaSyncService {
                issueCheckpoint = try await captureIssueCheckpoint(service: deltaService)
                try ensureOperationIsCurrent(generation: generation, destination: destination)
            } else {
                issueCheckpoint = nil
            }
            let preview = try await validatedPreview(
                id: confirmedPreviewID,
                service: service,
                generation: generation,
                destination: destination
            )
            guard let data = preview.data else {
                throw SyncError.notAvailable("目标后端还没有数据")
            }
            if service is any AuthoritativeSyncService {
                let snapshot = AuthoritativeSyncSnapshot(data: data, revision: preview.revision ?? 0)
                try importAuthoritativeSnapshot(snapshot, into: store, allowDestructive: true)
                if let issueCheckpoint {
                    initializeIssueJournal(store: store, cursor: issueCheckpoint)
                }
            } else {
                try importRemoteData(data, into: store, description: "采用 \(config.backend.rawValue) 数据前备份", allowDestructive: true)
                guard let fingerprint = syncFingerprint(data) else {
                    throw SyncError.invalidResponse("无法记录文件同步基线")
                }
                UserDefaults.standard.set(fingerprint, forKey: fileSyncFingerprintKey)
            }
            pendingRemotePreview = nil
            config.lastSyncDate = Date()
            status = .success(Date())
            lastSyncDirection = "\(config.backend.rawValue) → 本机（用户确认）"
            resumeAutomaticSync(store: store)
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func previewRemoteData(store: DataStore) async throws -> SyncDataPreview {
        guard config.enabled, let service = makeService() else {
            throw SyncError.notAvailable("同步配置不完整")
        }
        let generation = operationGeneration
        let destination = syncDestinationKey
        let data: Data?
        let revision: Int64?
        if let authoritativeService = service as? any AuthoritativeSyncService {
            let snapshot = try await authoritativeService.downloadSnapshot()
            data = snapshot?.data
            revision = snapshot?.revision
        } else {
            data = try await service.download()
            revision = nil
        }
        try ensureOperationIsCurrent(generation: generation, destination: destination)

        let object: [String: Any]
        if let data {
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  decoded["records"] is [String: [String: Int]] else {
                throw SyncError.invalidResponse("目标端数据格式无效")
            }
            object = decoded
        } else {
            object = [:]
        }
        let remoteRecords = object["records"] as? [String: [String: Int]] ?? [:]
        let remoteSupportTotal = remoteRecords.values.reduce(0) { total, day in
            total + day.values.reduce(0, +)
        }
        let localSupportTotal = store.records.values.reduce(0) { total, day in
            total + day.values.reduce(0, +)
        }
        let remoteIssueCount = (object["trackedIssues"] as? [[String: Any]])?.lazy.filter {
            $0["deletedAt"] == nil || $0["deletedAt"] is NSNull
        }.count ?? 0
        let remoteDepartmentCount = (object["departments"] as? [String])?.count ?? 0
        let remoteMemberCount = (object["teamMembers"] as? [Any])?.count
            ?? (object["bugTeamMembers"] as? [String])?.count
            ?? 0
        let schemaVersion = (object["schemaVersion"] as? NSNumber)?.intValue ?? 1
        let id = UUID()
        pendingRemotePreview = PendingRemotePreview(
            id: id,
            destinationKey: destination,
            data: data,
            revision: revision,
            fingerprint: data.flatMap { syncFingerprint($0) }
        )
        return SyncDataPreview(
            id: id,
            remoteExists: data != nil,
            localSupportTotal: localSupportTotal,
            remoteSupportTotal: remoteSupportTotal,
            localIssueCount: store.trackedIssues.lazy.filter { $0.deletedAt == nil }.count,
            remoteIssueCount: remoteIssueCount,
            localDepartmentCount: store.departments.count,
            remoteDepartmentCount: remoteDepartmentCount,
            localMemberCount: store.teamMembers.count,
            remoteMemberCount: remoteMemberCount,
            remoteSchemaVersion: schemaVersion
        )
    }

    func acceptOnlineSnapshot(store: DataStore) async throws {
        guard config.enabled,
              let service = makeService() as? any AuthoritativeSyncService else {
            throw SyncError.notAvailable("仅 HTTP API 团队同步支持采用线上版本")
        }
        if case .syncing = status {
            throw SyncError.notAvailable("另一项同步操作正在进行，请稍后重试")
        }

        status = .syncing
        do {
            let issueCheckpoint: Int64?
            if let deltaService = service as? any IssueDeltaSyncService {
                issueCheckpoint = try await captureIssueCheckpoint(service: deltaService)
            } else {
                issueCheckpoint = nil
            }
            guard let snapshot = try await service.downloadSnapshot() else {
                throw SyncError.notAvailable("线上还没有可用数据")
            }
            try importAuthoritativeSnapshot(snapshot, into: store, allowDestructive: true)
            try recordAuthoritativeBaseline(store: store, revision: snapshot.revision, excludeIssues: true)
            if let issueCheckpoint {
                initializeIssueJournal(store: store, cursor: issueCheckpoint)
            }
            config.lastSyncDate = Date()
            status = .success(Date())
            DevLog.shared.info("Sync", "已放弃本地冲突内容并采用线上修订版 \(snapshot.revision)")
        } catch {
            status = .error(error.localizedDescription)
            throw error
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
        guard config.enabled, config.intervalMinutes > 0, !automaticSyncPaused else { return }
        let configuredInterval = TimeInterval(config.intervalMinutes * 60)
        // 团队 HTTP 工作区需要及时感知 Web 和其他客户端的 revision。
        // 其他文件型后端仍尊重用户配置，避免无意义的磁盘/网络轮询。
        let interval = config.backend == .httpAPI ? min(configuredInterval, 30) : configuredInterval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.sync(store: store)
            }
        }
    }

    func makeWebPortalURL(token: String? = nil) -> URL? {
        let portal = config.webPortalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = portal.isEmpty ? config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : portal
        guard !base.isEmpty else { return nil }
        guard var components = URLComponents(string: base) else { return nil }

        let resolvedToken = (token ?? loadWebPortalToken()).trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedToken.isEmpty {
            var fragmentItems = URLComponents()
            fragmentItems.queryItems = [URLQueryItem(name: "token", value: resolvedToken)]
            components.fragment = fragmentItems.percentEncodedQuery
        }

        return components.url
    }

    func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Helpers

    private func ensureOperationIsCurrent(generation: Int, destination: String) throws {
        guard generation == operationGeneration, destination == syncDestinationKey else {
            throw SyncError.conflict("同步目标已变化，本次操作已取消；请重新预览后确认。")
        }
    }

    private func validatedPreview(
        id: UUID,
        service: any CloudSyncService,
        generation: Int,
        destination: String
    ) async throws -> PendingRemotePreview {
        guard let preview = pendingRemotePreview,
              preview.id == id,
              preview.destinationKey == destination else {
            throw SyncError.conflict("同步预览已失效，请重新预览目标端数据。")
        }
        try ensureOperationIsCurrent(generation: generation, destination: destination)

        if let authoritative = service as? any AuthoritativeSyncService {
            let current = try await authoritative.downloadSnapshot()
            try ensureOperationIsCurrent(generation: generation, destination: destination)
            guard current?.revision == preview.revision,
                  current?.data != nil || preview.data == nil else {
                pendingRemotePreview = nil
                throw SyncError.conflict("预览后线上修订版已变化，请重新预览。")
            }
        } else {
            let current = try await service.download()
            try ensureOperationIsCurrent(generation: generation, destination: destination)
            let currentFingerprint = current.flatMap { syncFingerprint($0) }
            guard currentFingerprint == preview.fingerprint,
                  current != nil || preview.data == nil else {
                pendingRemotePreview = nil
                throw SyncError.conflict("预览后目标文件已变化，请重新预览。")
            }
        }
        return preview
    }

    private func captureIssueCheckpoint(service: any IssueDeltaSyncService) async throws -> Int64 {
        let state = IssueSyncJournal.shared.state(for: issueSyncServerKey)
        let page = try await service.downloadIssueEvents(after: state.cursor)
        return page.latestCursor ?? page.nextCursor
    }

    private func initializeIssueJournal(store: DataStore, cursor: Int64) {
        var state = IssueSyncJournal.shared.state(for: issueSyncServerKey)
        state.cursor = cursor
        state.baseline = Dictionary(uniqueKeysWithValues: store.trackedIssues.map { ($0.syncID, $0) })
        state.outbox = []
        state.conflicts = []
        state.bootstrapped = true
        IssueSyncJournal.shared.save(state, for: issueSyncServerKey)
        updateIssueSyncIndicators(state)
    }

    private var authoritativeRevisionKey: String {
        "sync.authoritative.revision.\(syncDestinationKey)"
    }

    private var authoritativeFingerprintKey: String {
        "sync.authoritative.fingerprint.\(syncDestinationKey)"
    }

    private var fileSyncFingerprintKey: String {
        "sync.file.fingerprint.\(syncDestinationKey)"
    }

    private var syncDestinationKey: String {
        let endpoint = config.serverURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.newlines))
            .lowercased()
        let identity: String
        switch config.backend {
        case .iCloud:
            identity = "default"
        case .webDAV:
            identity = identityDigest(config.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case .httpAPI:
            identity = identityDigest(loadCredential().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return "\(config.backend.rawValue.lowercased())|\(endpoint)|\(identity)"
    }

    private func syncAuthoritative(
        store: DataStore,
        service: any AuthoritativeSyncService
    ) async throws {
        if let deltaService = service as? any IssueDeltaSyncService {
            let serverKey = issueSyncServerKey
            var journalState = IssueSyncJournal.shared.state(for: serverKey)
            if !journalState.bootstrapped {
                try await syncWorkspaceSnapshot(store: store, service: service, preserveIssues: false)
                journalState.baseline = Dictionary(uniqueKeysWithValues: store.trackedIssues.map { ($0.syncID, $0) })
                journalState.bootstrapped = true
                IssueSyncJournal.shared.save(journalState, for: serverKey)
            }
            try await syncIssueDeltas(store: store, service: deltaService, serverKey: serverKey)
            try await syncWorkspaceSnapshot(store: store, service: service, preserveIssues: true)
            try await syncIssueDeltas(store: store, service: deltaService, serverKey: serverKey)
            return
        }
        try await syncWorkspaceSnapshot(store: store, service: service, preserveIssues: false)
    }

    private var issueSyncServerKey: String {
        syncDestinationKey
    }

    private func identityDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func migrateLegacySyncIdentityIfNeeded() {
        let endpoint = config.serverURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.newlines))
            .lowercased()
        guard !endpoint.isEmpty else { return }
        let legacyDestination = "\(config.backend.rawValue.lowercased())|\(endpoint)"
        let migrationKey = "sync.identity-key-migrated.\(legacyDestination)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        let destination = syncDestinationKey
        let keyPairs = [
            ("sync.authoritative.revision.\(legacyDestination)", "sync.authoritative.revision.\(destination)"),
            ("sync.authoritative.fingerprint.\(legacyDestination)", "sync.authoritative.fingerprint.\(destination)"),
            ("sync.authoritative.fingerprint.\(legacyDestination).workspace-v2", "sync.authoritative.fingerprint.\(destination).workspace-v2"),
            ("sync.file.fingerprint.\(legacyDestination)", "sync.file.fingerprint.\(destination)")
        ]
        for (legacy, current) in keyPairs where defaults.object(forKey: current) == nil {
            if let value = defaults.object(forKey: legacy) {
                defaults.set(value, forKey: current)
            }
        }
        if config.backend == .httpAPI {
            // Older issue journals used only the endpoint, even before the
            // authoritative snapshot keys gained their backend prefix.
            IssueSyncJournal.shared.migrateStateIfNeeded(from: endpoint, to: destination)
        }
        defaults.set(true, forKey: migrationKey)
    }

    private func syncWorkspaceSnapshot(
        store: DataStore,
        service: any AuthoritativeSyncService,
        preserveIssues: Bool
    ) async throws {
        guard let localData = exportData(from: store),
              let localFingerprint = syncFingerprint(localData, excludeIssues: preserveIssues) else {
            throw SyncError.uploadFailed("导出本地同步数据失败")
        }

        let defaults = UserDefaults.standard
        let storedRevision = (defaults.object(forKey: authoritativeRevisionKey) as? NSNumber)?.int64Value
        let fingerprintKey = preserveIssues ? authoritativeFingerprintKey + ".workspace-v2" : authoritativeFingerprintKey
        let storedFingerprint = defaults.string(forKey: fingerprintKey)
        let remote = try await service.downloadSnapshot()

        guard let remote else {
            let revision = try await service.uploadSnapshot(localData, expectedRevision: 0)
            try await refreshAuthoritativeBaseline(store: store, service: service, fallbackRevision: revision)
            DevLog.shared.info("Sync", "已初始化线上数据源")
            return
        }

        // 首次连接一个已有线上工作区时，线上快照必须获胜。若曾同步过的
        // 工作区被重置为 revision 0，也按线上状态处理，避免旧本地数据回灌。
        if storedRevision == nil || storedFingerprint == nil || (remote.revision == 0 && storedRevision != nil) {
            if remote.revision == 0 && storedRevision == nil {
                let revision = try await service.uploadSnapshot(localData, expectedRevision: 0)
                try await refreshAuthoritativeBaseline(store: store, service: service, fallbackRevision: revision, preserveIssues: preserveIssues)
                DevLog.shared.info("Sync", "已将初始数据提交到线上平台")
            } else {
                throw SyncError.conflict("目标工作区已有数据。请在同步设置中明确选择“上传本机数据”或“采用目标端数据”。")
            }
            return
        }

        let localChanged = localFingerprint != storedFingerprint
        let remoteChanged = remote.revision != storedRevision

        switch (localChanged, remoteChanged) {
        case (false, false):
            DevLog.shared.info("Sync", "本地与线上数据一致")
        case (false, true):
            try importAuthoritativeSnapshot(remote, into: store, preserveIssues: preserveIssues)
            DevLog.shared.info("Sync", "已同步线上修订版 \(remote.revision)")
        case (true, false):
            let revision = try await service.uploadSnapshot(localData, expectedRevision: storedRevision ?? 0)
            try await refreshAuthoritativeBaseline(store: store, service: service, fallbackRevision: revision, preserveIssues: preserveIssues)
            DevLog.shared.info("Sync", "本地修改已提交为线上修订版 \(revision)")
        case (true, true):
            if syncFingerprint(remote.data, excludeIssues: preserveIssues) == localFingerprint {
                try importAuthoritativeSnapshot(remote, into: store, preserveIssues: preserveIssues)
                DevLog.shared.info("Sync", "线上已包含本地提交，按修订版 \(remote.revision) 恢复同步基线")
                return
            }
            throw SyncError.conflict(
                "本地和线上数据都已修改。线上当前为修订版 \(remote.revision)，本地内容未被覆盖；请先处理同步冲突。"
            )
        }
    }

    private func refreshAuthoritativeBaseline(
        store: DataStore,
        service: any AuthoritativeSyncService,
        fallbackRevision: Int64,
        preserveIssues: Bool = false
    ) async throws {
        if let snapshot = try await service.downloadSnapshot() {
            try importAuthoritativeSnapshot(snapshot, into: store, preserveIssues: preserveIssues)
            return
        }
        try recordAuthoritativeBaseline(store: store, revision: fallbackRevision, excludeIssues: preserveIssues)
    }

    private func importAuthoritativeSnapshot(
        _ snapshot: AuthoritativeSyncSnapshot,
        into store: DataStore,
        preserveIssues: Bool = false,
        allowDestructive: Bool = false
    ) throws {
        let importedData: Data
        if preserveIssues {
            guard let data = replacingTrackedIssues(in: snapshot.data, with: store.trackedIssues) else {
                throw SyncError.invalidResponse("无法保留本机 Issue 并生成同步快照")
            }
            importedData = data
        } else {
            importedData = snapshot.data
        }
        try importRemoteData(
            importedData,
            into: store,
            description: "导入线上修订版 \(snapshot.revision) 前备份",
            allowDestructive: allowDestructive
        )
        try recordAuthoritativeBaseline(store: store, revision: snapshot.revision, excludeIssues: preserveIssues)
    }

    private func replacingTrackedIssues(in data: Data, with issues: [TrackedIssue]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issueData = try? JSONEncoder().encode(issues),
              let issueArray = try? JSONSerialization.jsonObject(with: issueData) else {
            return nil
        }
        object["trackedIssues"] = issueArray
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func syncIssueDeltas(
        store: DataStore,
        service: any IssueDeltaSyncService,
        serverKey: String
    ) async throws {
        var state = IssueSyncJournal.shared.state(for: serverKey)
        let firstPage = try await service.downloadIssueEvents(after: state.cursor)
        guard firstPage.cursorReset != true else {
            throw SyncError.conflict("增量同步历史已过期。为避免误删或覆盖，请在同步设置中明确选择“采用目标端数据”或“上传本机数据”。")
        }
        var events = firstPage.events
        var nextCursor = firstPage.nextCursor
        let targetCursor = firstPage.latestCursor ?? firstPage.nextCursor
        while nextCursor < targetCursor {
            let nextPage = try await service.downloadIssueEvents(after: nextCursor)
            guard nextPage.cursorReset != true else {
                throw SyncError.conflict("读取增量同步历史时游标失效。为避免误删或覆盖，请重新选择同步方向。")
            }
            guard nextPage.nextCursor > nextCursor else {
                throw SyncError.invalidResponse("增量同步分页未向前推进")
            }
            events.append(contentsOf: nextPage.events)
            nextCursor = nextPage.nextCursor
        }
        var localByID = Dictionary(uniqueKeysWithValues: store.trackedIssues.map { ($0.syncID, $0) })

        for event in events where event.type.hasPrefix("issue.") {
            guard let remote = event.payload else { continue }
            let key = remote.syncID
            let base = state.baseline[key]
            let local = localByID[key]
            state.outbox.removeAll { $0.issueID == key }

            if issuesSyncEquivalent(local, base) {
                localByID[key] = remote
            } else if let local {
                let (merged, overlap) = mergeDisjointIssueChanges(base: base, local: local, remote: remote)
                if let merged {
                    localByID[key] = merged
                } else {
                    state.conflicts.removeAll { $0.issueID == key }
                    state.conflicts.append(IssueSyncConflict(
                        issueID: key,
                        base: base,
                        local: local,
                        remote: remote,
                        overlappingFields: overlap
                    ))
                }
            } else if base == nil {
                localByID[key] = remote
            } else {
                state.conflicts.removeAll { $0.issueID == key }
                state.conflicts.append(IssueSyncConflict(
                    issueID: key,
                    base: base,
                    local: nil,
                    remote: remote,
                    overlappingFields: ["deleted locally"]
                ))
            }
            state.baseline[key] = remote
        }
        state.cursor = max(state.cursor, nextCursor)
        applyIssueMap(localByID, to: store)

        let conflictedIDs = Set(state.conflicts.map(\.issueID))
        let queuedIDs = Set(state.outbox.map(\.issueID))
        let allIDs = Set(state.baseline.keys).union(localByID.keys)
        for key in allIDs {
            guard !conflictedIDs.contains(key), !queuedIDs.contains(key) else { continue }
            let base = state.baseline[key]
            let local = localByID[key]
            if issuesSyncEquivalent(base, local) { continue }
            if local == nil || local?.deletedAt != nil {
                if let base, base.deletedAt == nil {
                    state.outbox.append(IssueSyncOperation(issueID: key, kind: .delete, baseRevision: base.revision, issue: nil))
                }
            } else if let local {
                state.outbox.append(IssueSyncOperation(issueID: key, kind: .upsert, baseRevision: base?.revision ?? 0, issue: local))
            }
        }
        IssueSyncJournal.shared.save(state, for: serverKey)

        for operation in state.outbox {
            do {
                let committed: TrackedIssue
                switch operation.kind {
                case .upsert:
                    guard let issue = operation.issue else { continue }
                    committed = try await service.upsertIssue(issue, baseRevision: operation.baseRevision, operationID: operation.id)
                case .delete:
                    committed = try await service.deleteIssue(id: operation.issueID, baseRevision: operation.baseRevision, operationID: operation.id)
                }
                let localAtCommit = localByID[operation.issueID]
                let canApplyRemote = switch operation.kind {
                case .upsert:
                    issuesSyncEquivalent(localAtCommit, operation.issue)
                case .delete:
                    localAtCommit == nil
                }
                if canApplyRemote {
                    localByID[committed.syncID] = committed
                }
                state.baseline[committed.syncID] = committed
                state.outbox.removeAll { $0.id == operation.id }
                state.conflicts.removeAll { $0.issueID == committed.syncID }
                applyIssueMap(localByID, to: store)
                IssueSyncJournal.shared.save(state, for: serverKey)
            } catch IssueDeltaSyncError.conflict(let remote) {
                let key = operation.issueID
                let local = localByID[key]
                let previousBase = state.baseline[key]
                state.baseline[key] = remote
                state.outbox.removeAll { $0.id == operation.id }
                state.conflicts.removeAll { $0.issueID == operation.issueID }
                state.conflicts.append(IssueSyncConflict(
                    issueID: operation.issueID,
                    base: operation.baseRevision == 0 ? nil : previousBase,
                    local: local,
                    remote: remote,
                    overlappingFields: ["server revision"]
                ))
                IssueSyncJournal.shared.save(state, for: serverKey)
            } catch {
                if let index = state.outbox.firstIndex(where: { $0.id == operation.id }) {
                    state.outbox[index].attempts += 1
                }
                IssueSyncJournal.shared.save(state, for: serverKey)
                updateIssueSyncIndicators(state)
                throw error
            }
        }

        updateIssueSyncIndicators(state)
        if !state.conflicts.isEmpty {
            throw SyncError.conflict("有 \(state.conflicts.count) 条 Issue 存在字段冲突，已保存本地与线上快照，可在同步设置中选择保留版本。")
        }
    }

    private func applyIssueMap(_ issues: [String: TrackedIssue], to store: DataStore) {
        store.trackedIssues = issues.values.sorted {
            if $0.issueNumber == $1.issueNumber { return $0.createdAt < $1.createdAt }
            return $0.issueNumber < $1.issueNumber
        }
    }

    private func updateIssueSyncIndicators(_ state: IssueSyncJournalState) {
        issueConflicts = state.conflicts.sorted { $0.createdAt > $1.createdAt }
        pendingIssueOperations = state.outbox.count
    }

    func resolveIssueConflict(_ conflictID: UUID, keepLocal: Bool, store: DataStore) {
        let serverKey = issueSyncServerKey
        var state = IssueSyncJournal.shared.state(for: serverKey)
        guard let conflict = state.conflicts.first(where: { $0.id == conflictID }) else { return }
        var localByID = Dictionary(uniqueKeysWithValues: store.trackedIssues.map { ($0.syncID, $0) })
        let key = conflict.issueID
        state.baseline[key] = conflict.remote
        if keepLocal, var local = conflict.local {
            local.revision = conflict.remote.revision
            local.updatedBy = conflict.remote.updatedBy
            local.deletedAt = nil
            localByID[key] = local
            state.outbox.removeAll { $0.issueID == conflict.issueID }
            state.outbox.append(IssueSyncOperation(
                issueID: conflict.issueID,
                kind: .upsert,
                baseRevision: conflict.remote.revision,
                issue: local
            ))
        } else {
            localByID[key] = conflict.remote
            state.outbox.removeAll { $0.issueID == conflict.issueID }
        }
        state.conflicts.removeAll { $0.id == conflictID }
        applyIssueMap(localByID, to: store)
        IssueSyncJournal.shared.save(state, for: serverKey)
        updateIssueSyncIndicators(state)
    }

    private func recordAuthoritativeBaseline(store: DataStore, revision: Int64, excludeIssues: Bool = false) throws {
        guard let projectedData = exportData(from: store),
              let fingerprint = syncFingerprint(projectedData, excludeIssues: excludeIssues) else {
            throw SyncError.invalidResponse("无法记录同步基线")
        }
        let defaults = UserDefaults.standard
        defaults.set(revision, forKey: authoritativeRevisionKey)
        defaults.set(fingerprint, forKey: excludeIssues ? authoritativeFingerprintKey + ".workspace-v2" : authoritativeFingerprintKey)
    }

    private func exportData(from store: DataStore) -> Data? {
        store.exportSyncData()
    }

    private func importRemoteData(
        _ data: Data,
        into store: DataStore,
        description: String,
        allowDestructive: Bool = false
    ) throws {
        guard SnapshotManager.shared.saveSnapshot(from: store, description: description) else {
            throw SyncError.notAvailable("无法创建覆盖前快照，已停止导入")
        }
        guard store.importSyncData(data, allowDestructive: allowDestructive) else {
            throw SyncError.invalidResponse("远端数据格式不兼容或会导致大量数据减少，已停止导入")
        }
    }

    private func syncFingerprint(_ data: Data, excludeIssues: Bool = false) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        object.removeValue(forKey: "lastModified")
        object.removeValue(forKey: "revision")
        object.removeValue(forKey: "lastModifiedBy")
        if excludeIssues {
            object.removeValue(forKey: "trackedIssues")
        }
        if var config = object["feishuBotConfig"] as? [String: Any] {
            config.removeValue(forKey: "lastSentTimes")
            config.removeValue(forKey: "lastSentDateTime")
            config.removeValue(forKey: "issueMonthlyReportLastSentMonth")
            object["feishuBotConfig"] = config
        }
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

}
