import SwiftUI

struct SyncTab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var syncManager = SyncManager.shared
    @State private var credentialInput = ""
    @State private var webPortalTokenInput = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var syncing = false
    @State private var uploading = false
    @State private var didLoadSyncSecrets = false
    @State private var showingAcceptOnlineConfirmation = false
    @State private var pendingBackend: SyncConfig.Backend?
    @State private var showingBackendSwitchConfirmation = false
    @State private var remotePreviewText = ""
    @State private var remotePreview: SyncDataPreview?
    @State private var showingRemoteAdoptionConfirmation = false
    @State private var showingLocalUploadConfirmation = false

    var body: some View {
        Form {
            let webPortalURL = currentWebPortalURL
            Section("云端同步") {
                Toggle(isOn: $syncManager.config.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用数据同步")
                        Text("自动同步数据到云端，支持多设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: syncManager.config.enabled) { _, enabled in
                    if enabled {
                        syncManager.startPeriodicSync(store: store)
                    } else {
                        syncManager.stopPeriodicSync()
                    }
                }
            }

            Section("当前数据流") {
                SettingsStatusRow(
                    title: "本地数据",
                    value: "本机工作台",
                    systemImage: "macbook",
                    tint: .blue
                )
                SettingsStatusRow(
                    title: "上次方向",
                    value: syncManager.lastSyncDirection,
                    systemImage: "arrow.left.arrow.right",
                    tint: syncManager.automaticSyncPaused ? .orange : .secondary
                )
                if syncManager.automaticSyncPaused {
                    SettingsHint(text: "自动同步已暂停。请选择上传本机数据或采用目标端数据后才会恢复，切换后端本身不会再覆盖任何内容。")
                }
                SettingsStatusRow(
                    title: "服务端",
                    value: syncBackendSummary,
                    systemImage: syncManager.config.backend == .httpAPI ? "server.rack" : "icloud",
                    tint: syncManager.config.enabled ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "同步能力",
                    value: syncTokenState,
                    systemImage: credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key.slash" : "key.fill",
                    tint: credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .orange : .green
                )
                SettingsStatusRow(
                    title: "网页工作台",
                    value: webPortalState,
                    systemImage: "globe",
                    tint: webPortalURL == nil ? .orange : .green
                )
                SettingsHint(text: "新服务端会用 Token 自动识别 workspace；同步 Token 只负责 /sync，网页 Token 负责 /api 和网页面板。")
            }

            Section("同步后端") {
                Picker("存储方式", selection: Binding(
                    get: { syncManager.config.backend },
                    set: { backend in
                        guard backend != syncManager.config.backend else { return }
                        pendingBackend = backend
                        showingBackendSwitchConfirmation = true
                    }
                )) {
                    ForEach(SyncConfig.Backend.allCases, id: \.self) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(syncing || uploading || testing || syncManager.isBusy)

                switch syncManager.config.backend {
                case .iCloud:
                    Text("通过 iCloud Drive 文件同步，无需额外配置，登录 Apple ID 即可")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .webDAV:
                    TextField("WebDAV URL", text: serverURLBinding,
                              prompt: Text("https://dav.example.com/sync"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .disabled(syncManager.isBusy)
                    TextField("用户名", text: usernameBinding)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .disabled(syncManager.isBusy)
                    SecureField("密码", text: $credentialInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: credentialInput) { _, _ in saveCredential() }
                        .disabled(syncManager.isBusy)
                case .httpAPI:
                    TextField("同步服务器 URL", text: serverURLBinding,
                              prompt: Text("https://sync.example.com"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .disabled(syncManager.isBusy)
                    SecureField("同步 Token", text: $credentialInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: credentialInput) { _, _ in saveCredential() }
                        .disabled(syncManager.isBusy)
                    Text("这里只用于 /sync 数据同步，不再承担网页后台登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        testConnection()
                    }
                    .controlSize(.small)
                    .disabled(testing)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }

                if syncManager.automaticSyncPaused {
                    HStack {
                        Button("上传本机数据并启用") {
                            previewLocalUpload()
                        }
                        .controlSize(.small)
                        .disabled(uploading || !manualSyncReady)
                        Button("采用目标端数据并启用", role: .destructive) {
                            previewRemoteAdoption()
                        }
                        .controlSize(.small)
                        .disabled(syncing || !manualSyncReady)
                    }
                }
            }

            Section("网页面板") {
                TextField("网页地址", text: $syncManager.config.webPortalURL,
                          prompt: Text("留空则默认使用同步服务器地址"))
                    .textFieldStyle(UnderlineTextFieldStyle())
                SecureField("网页访问 Token", text: $webPortalTokenInput)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: webPortalTokenInput) { _, _ in
                        syncManager.saveWebPortalToken(webPortalTokenInput)
                    }
                Text("用于访问 /api 管理页面，可与同步 Token 分开配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("在浏览器中打开") {
                        if let url = webPortalURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .disabled(webPortalURL == nil)

                    Button("复制链接") {
                        if let url = webPortalURL {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .disabled(webPortalURL == nil)

                    Spacer()
                }
            }

            Section("同步设置") {
                Picker("自动同步间隔", selection: $syncManager.config.intervalMinutes) {
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                    Text("仅手动").tag(0)
                }
                .onChange(of: syncManager.config.intervalMinutes) { _, _ in
                    syncManager.startPeriodicSync(store: store)
                }

                HStack {
                    Button(syncing ? "同步中…" : "立即同步") {
                        manualSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(syncing || !manualSyncReady || syncManager.automaticSyncPaused)

                    if syncManager.config.backend == .httpAPI {
                        Button(uploading ? "上传中…" : "上传本地数据") {
                            previewLocalUpload()
                        }
                        .controlSize(.small)
                        .disabled(syncing || uploading || !manualSyncReady)
                        .help("将当前本机数据作为一个新修订版提交到服务端")
                    }

                    Spacer()

                    if let lastSync = syncManager.config.lastSyncDate {
                        Text("上次同步：\(formatDate(lastSync))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                syncStatusView
            }

            if syncManager.config.backend == .httpAPI &&
                (syncManager.pendingIssueOperations > 0 || !syncManager.issueConflicts.isEmpty) {
                Section("Issue 增量队列") {
                    if syncManager.pendingIssueOperations > 0 {
                        Label("\(syncManager.pendingIssueOperations) 条离线操作等待提交", systemImage: "tray.and.arrow.up")
                            .foregroundStyle(.orange)
                    }
                    ForEach(syncManager.issueConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Issue \(conflict.issueID)", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.caption.weight(.semibold))
                            Text("冲突字段：\(conflict.overlappingFields.joined(separator: "、"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("本机").font(.caption2).foregroundStyle(.secondary)
                                    Text(conflict.local?.title ?? "已在本机删除").font(.caption)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("线上 r\(conflict.remote.revision)").font(.caption2).foregroundStyle(.secondary)
                                    Text(conflict.remote.title).font(.caption)
                                }
                            }
                            HStack {
                                Button("保留本机并重试") {
                                    syncManager.resolveIssueConflict(conflict.id, keepLocal: true, store: store)
                                }
                                .controlSize(.small)
                                .disabled(conflict.local == nil)
                                Button("采用线上") {
                                    syncManager.resolveIssueConflict(conflict.id, keepLocal: false, store: store)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("同步范围") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("共享数据：支持记录、日报、问题追踪、团队成员")
                    Text("本机配置：Jira、Linear、飞书、AI、快捷键、MCP（不会被远端覆盖）")
                    Text("敏感数据：Token、Secret、API Key 仅保存在 Keychain")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: isActive) { _, active in
            if active { loadSyncSecretsIfNeeded() }
        }
        .task {
            if isActive { loadSyncSecretsIfNeeded() }
        }
        .confirmationDialog(
            "采用线上版本？",
            isPresented: $showingAcceptOnlineConfirmation,
            titleVisibility: .visible
        ) {
            Button("放弃本地修改并采用线上版本", role: .destructive) {
                acceptOnlineSnapshot()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机尚未提交的冲突内容会被线上数据替换。线上平台仍保持不变。")
        }
        .confirmationDialog(
            "切换到 \(pendingBackend?.rawValue ?? "新后端")",
            isPresented: $showingBackendSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("上传本机数据到目标端") {
                commitBackendSwitch(action: .uploadLocal)
            }
            Button("采用目标端数据", role: .destructive) {
                commitBackendSwitch(action: .adoptRemote)
            }
            Button("仅切换，保持暂停") {
                commitBackendSwitch(action: .pauseOnly)
            }
            Button("取消", role: .cancel) {
                pendingBackend = nil
            }
        } message: {
            Text("切换后端不会自动同步。本机集成配置和 Keychain 凭证不会被目标端覆盖；采用目标端数据前会自动创建快照。")
        }
        .confirmationDialog(
            "确认采用目标端数据？",
            isPresented: $showingRemoteAdoptionConfirmation,
            titleVisibility: .visible
        ) {
            Button("采用目标端数据", role: .destructive) {
                adoptSelectedBackendData()
            }
            Button("保持暂停", role: .cancel) {}
        } message: {
            Text(remotePreviewText)
        }
        .confirmationDialog(
            "确认用本机数据替换目标端？",
            isPresented: $showingLocalUploadConfirmation,
            titleVisibility: .visible
        ) {
            Button("上传本机数据", role: .destructive) {
                uploadLocalSnapshot()
            }
            Button("保持暂停", role: .cancel) {}
        } message: {
            Text(remotePreviewText)
        }
    }

    private func loadSyncSecretsIfNeeded() {
        guard !didLoadSyncSecrets else { return }
        didLoadSyncSecrets = true
        credentialInput = syncManager.loadCredential()
        webPortalTokenInput = syncManager.loadWebPortalToken()
    }

    private var serverURLBinding: Binding<String> {
        Binding(
            get: { syncManager.config.serverURL },
            set: { value in
                guard value != syncManager.config.serverURL else { return }
                syncManager.config.serverURL = value
                syncManager.destinationConfigurationDidChange()
            }
        )
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { syncManager.config.username },
            set: { value in
                guard value != syncManager.config.username else { return }
                syncManager.config.username = value
                syncManager.destinationConfigurationDidChange()
            }
        )
    }

    private var syncBackendSummary: String {
        if !syncManager.config.enabled {
            return "未启用"
        }
        switch syncManager.config.backend {
        case .iCloud:
            return "iCloud"
        case .webDAV:
            return syncManager.config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "WebDAV 未配置" : "WebDAV"
        case .httpAPI:
            let serverURL = syncManager.config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.newlines))
            return serverURL.isEmpty ? "服务端未配置" : serverURL
        }
    }

    private var syncTokenState: String {
        switch syncManager.config.backend {
        case .iCloud:
            return "无需 Token"
        case .webDAV:
            return credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未保存密码" : "已保存凭据"
        case .httpAPI:
            return credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "缺同步 Token" : "sync token 已保存"
        }
    }

    private var webPortalState: String {
        guard currentWebPortalURL != nil else { return "缺网页地址或 Token" }
        return webPortalTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "使用同步 Token 登录" : "web token 已配置"
    }

    private var currentWebPortalURL: URL? {
        syncManager.makeWebPortalURL(token: webPortalTokenInput)
    }

    private var manualSyncReady: Bool {
        switch syncManager.config.backend {
        case .iCloud:
            return true
        case .webDAV:
            return !syncManager.config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .httpAPI:
            return !syncManager.config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.status {
        case .idle:
            EmptyView()
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在同步…").font(.caption).foregroundStyle(.secondary)
            }
        case .success(let date):
            Text("同步成功 \(formatDate(date))")
                .font(.caption)
                .foregroundStyle(.green)
        case .conflict(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("检测到多端修改冲突", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("采用线上版本") {
                    showingAcceptOnlineConfirmation = true
                }
                .controlSize(.small)
            }
        case .error(let msg):
            Text("同步失败：\(msg)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func saveCredential() {
        guard credentialInput != syncManager.loadCredential() else { return }
        syncManager.saveCredential(credentialInput)
        syncManager.destinationConfigurationDidChange()
    }

    private func testConnection() {
        if !credentialInput.isEmpty { saveCredential() }
        testing = true
        testResult = nil
        Task {
            let result = await syncManager.testConnection()
            switch result {
            case .success:
                testResult = "连接成功"
                testSuccess = true
            case .failure(let error):
                testResult = error.localizedDescription
                testSuccess = false
            }
            testing = false
        }
    }

    private func manualSync() {
        if !credentialInput.isEmpty { saveCredential() }
        syncing = true
        Task {
            await syncManager.sync(store: store, allowWhilePaused: false)
            syncing = false
        }
    }

    private func uploadLocalSnapshot() {
        guard let preview = remotePreview else {
            testResult = "目标端预览已失效，请重新预览"
            testSuccess = false
            return
        }
        if !credentialInput.isEmpty { saveCredential() }
        uploading = true
        Task {
            do {
                try await syncManager.uploadCurrentSnapshot(store: store, confirmedPreviewID: preview.id)
                testResult = "本地数据已提交"
                testSuccess = true
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
            remotePreview = nil
            uploading = false
        }
    }

    private func previewLocalUpload() {
        if !credentialInput.isEmpty { saveCredential() }
        syncing = true
        Task {
            do {
                let preview = try await syncManager.previewRemoteData(store: store)
                remotePreview = preview
                let target = preview.remoteExists
                    ? "目标端现有支持计数 \(preview.remoteSupportTotal)、可见问题 \(preview.remoteIssueCount)、部门 \(preview.remoteDepartmentCount)、成员 \(preview.remoteMemberCount)"
                    : "目标端当前为空"
                remotePreviewText = "\(target)。确认后将替换为本机支持计数 \(preview.localSupportTotal)、可见问题 \(preview.localIssueCount)、部门 \(preview.localDepartmentCount)、成员 \(preview.localMemberCount)。如果目标端在确认前发生变化，上传会自动取消。"
                showingLocalUploadConfirmation = true
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
            syncing = false
        }
    }

    private func acceptOnlineSnapshot() {
        syncing = true
        Task {
            do {
                try await syncManager.acceptOnlineSnapshot(store: store)
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
            syncing = false
        }
    }

    private enum BackendSwitchAction {
        case uploadLocal
        case adoptRemote
        case pauseOnly
    }

    private func commitBackendSwitch(action: BackendSwitchAction) {
        guard let backend = pendingBackend else { return }
        pendingBackend = nil
        guard syncManager.switchBackend(to: backend) else {
            testResult = "同步进行中，后端未切换，请稍后重试"
            testSuccess = false
            return
        }
        credentialInput = syncManager.loadCredential()
        switch action {
        case .uploadLocal:
            previewLocalUpload()
        case .adoptRemote:
            previewRemoteAdoption()
        case .pauseOnly:
            testResult = "已切换，自动同步保持暂停"
            testSuccess = true
        }
    }

    private func adoptSelectedBackendData() {
        guard let preview = remotePreview else {
            testResult = "目标端预览已失效，请重新预览"
            testSuccess = false
            return
        }
        if !credentialInput.isEmpty { saveCredential() }
        syncing = true
        Task {
            do {
                try await syncManager.adoptRemoteData(store: store, confirmedPreviewID: preview.id)
                testResult = "已采用目标端数据；本机配置保持不变"
                testSuccess = true
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
            remotePreview = nil
            syncing = false
        }
    }

    private func previewRemoteAdoption() {
        if !credentialInput.isEmpty { saveCredential() }
        syncing = true
        Task {
            do {
                let preview = try await syncManager.previewRemoteData(store: store)
                guard preview.remoteExists else {
                    throw SyncError.notAvailable("目标后端还没有数据")
                }
                remotePreview = preview
                remotePreviewText = preview.summary
                showingRemoteAdoptionConfirmation = true
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
            syncing = false
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
